classdef raspi < handle & matlab.mixin.CustomDisplay
    %RASPI Access Raspberry Pi hardware peripherals.
    %
    % obj = RASPI(DEVICEADDRESS, USERNAME, PASSWORD) creates a RASPI object
    % connected to the Raspberry Pi hardware at DEVICEADDRESS with login
    % credentials USERNAME and PASSWORD. The DEVICEADDRESS can be an 
    % IP address such as '192.168.0.10' or a hostname such as
    % 'raspberrypi-MJONES.foo.com'. 
    %
    % obj = RASPI creates a RASPI object connected to Raspberry Pi hardware
    % using saved values for DEVICEADDRESS, USERNAME and PASSWORD.
    % 
    % Type <a href="matlab:methods('raspi')">methods('raspi')</a> for a list of methods of the raspi object.
    %
    % Type <a href="matlab:properties('raspi')">properties('raspi')</a> for a list of properties of the raspi object.
    
    % Copyright 2013-2015 The MathWorks, Inc.
    
    properties (Dependent)
        DeviceAddress
        Port
    end
    
    properties (SetAccess = private)
        BoardName
        AvailableLEDs
        AvailableDigitalPins
        AvailableSPIChannels
        AvailableI2CBuses
        I2CBusSpeed
    end
    
    properties (Access = private)
        IpNode
        Credentials
        Sequence = 0
        Version
    end
    
    properties (Access = private)
        Ssh
        Scp
        Tcp
        BoardInfo
        DigitalPin
        LED
        I2C
        SPI
        
        % Maintain a map of created objects to gain exclusive access
        ConnectionMap = containers.Map
        Initialized = false
    end
    
    properties (Hidden, Constant)
        REQ_HEADER_SIZE            = 3
        REQ_HEADER_PRECISION       = 'uint32'
        REQ_MAX_PAYLOAD_SIZE       = 1024
        RESP_HEADER_SIZE           = 3
        RESP_HEADER_PRECISION      = 'uint32'
        RESP_MAX_PAYLOAD_SIZE      = (2000*1080*3)/2
        
        % Reserved
        REQUEST_ECHO               = 0
        REQUEST_VERSION            = 1
        REQUEST_AUTHORIZATION      = 2
        
        % LED requests
        REQUEST_LED_GET_TRIGGER    = 1000
        REQUEST_LED_SET_TRIGGER    = 1001
        REQUEST_LED_WRITE          = 1002
        
        % GPIO requests
        REQUEST_GPIO_INIT          = 2000
        REQUEST_GPIO_TERMINATE     = 2001
        REQUEST_GPIO_READ          = 2002
        REQUEST_GPIO_WRITE         = 2003
        REQUEST_GPIO_GET_DIRECTION = 2004

        % System requests
        REQUEST_SYSTEM_SYSTEM      = 10000
        REQUEST_SYSTEM_POPEN       = 10001
        REQUEST_I2C_BUS_AVAILABLE  = 3000
        
        % Constant used for storing board parameters
        BoardPref = 'Raspberry Pi';
    end
    
    properties (Hidden, Constant)
        EXPECTED_SERVER_VERSION = uint32([15, 1, 0])
        AVAILABLE_LED_TRIGGERS  = {'none', 'mmc0'}
        GPIO_INPUT              = 0
        GPIO_OUTPUT             = 1
        GPIO_UNSET              = 2
        GPIO_DIRECTION_NA       = 255
        NUMDIGITALPINS          = 32
        PINMODESTR              = {'input', 'output', 'unset'}
        UPINMODESTR             = {'DigitalInput','DigitalOutput','unset'}
    end
    
    methods (Hidden)
        function obj = raspi(hostname, username, password, port)
            % Create a connection to Raspberry Pi hardware.
            narginchk(0,4);
            
            % Register the error message catalog location
            [~] = registerrealtimecataloglocation(raspi.internal.getRaspiBaseRoot);
            
            hb = raspi.internal.BoardParameters(obj.BoardPref);
            if nargin < 1
                hostname = hb.getParam('hostname');
                if isempty(hostname)
                    error(message('raspi:utils:InvalidDeviceAddress'));
                end
            end
            if nargin < 2
                username = hb.getParam('username');
                if isempty(username)
                    error(message('raspi:utils:InvalidUsername'));
                end
            end
            if nargin < 3
                password = hb.getParam('password'); 
                if isempty(password)
                    error(message('raspi:utils:InvalidPassword'));
                end
            end
            if nargin < 4
                port = 18726;
            end
            
            % Validate and store device address
            try
                obj.IpNode = raspi.internal.ipnode(hostname, port);
                obj.Credentials = raspi.internal.credentials(username, password);
            catch ME
                throwAsCaller(ME);
            end
            
            % Check if there is an existing connection
            if isKey(obj.ConnectionMap, obj.IpNode.Hostname)
                error(message('raspi:utils:ConnectionExists', obj.IpNode.Hostname));
            end
            
            % Create an SSH client
            [~,hashKey] = fileparts(tempname);
            if ~isequal(obj.IpNode.Hostname, 'localhost') && ...
                    ~isequal(obj.IpNode.Hostname, '127.0.0.1')
                obj.Ssh = raspi.internal.sshclient(obj.IpNode.Hostname, ...
                    obj.Credentials.Username, obj.Credentials.Password);
                try
                    % Test SSH connection and accept SSL license
                    connect(obj.Ssh, ['echo `pgrep MATLABserver` | sudo tee /tmp/.' hashKey]);
                catch ME
                    baseME = MException(message('raspi:utils:SSHConnectionError', obj.IpNode.Hostname));
                    EX = addCause(baseME, ME);
                    throw(EX);
                end
            end
            
            % Create TCP client
            obj.Tcp = matlabshared.network.internal.TCPClient(...
                obj.IpNode.Hostname, obj.IpNode.Port);
            try
                connect(obj.Tcp);
            catch ME
                baseME = MException(message('raspi:utils:TCPConnectionError', obj.IpNode.Hostname));
                EX = addCause(baseME, ME);
                throw(EX);
            end
            
            % Authorize user 
            try
                authorize(obj,hashKey);
            catch ME
                error(message('raspi:utils:NotAuthorized', obj.DeviceAddress));
            end
            
            % Create an SCP client
            obj.Scp = raspi.internal.scpclient(obj.IpNode.Hostname, ...
                obj.Credentials.Username, obj.Credentials.Password);
            
            % Get and set server version. Note that the set method for
            % Version checks that we are compatible with the server.
            obj.Version = getServerVersion(obj);
            
            % Set board revision and static board information
            obj.BoardName = getBoardName(obj);
            hInfo = raspi.internal.BoardInfo(obj.BoardName);
            if isempty(hInfo.Board)
                error(message('raspi:utils:UnknownBoardRevision'));
            end
            obj.BoardInfo = hInfo.Board;
            
            % Tally all supported peripherals available on board
            getAvailablePeripherals(obj);
            
            % Add current connection to connectionMap
            obj.ConnectionMap(obj.IpNode.Hostname) = 0;
            obj.Initialized = true;
            
            % Store board parameters for a future session
            hb = raspi.internal.BoardParameters(obj.BoardPref);
            hb.setParam('hostname', obj.DeviceAddress);
            hb.setParam('username', obj.Credentials.Username);
            hb.setParam('password', obj.Credentials.Password);
        end
    end
    
    % GET / SET methods
    methods
        function value = get.DeviceAddress(obj)
            value = obj.IpNode.Hostname;
        end
        
        function value = get.Port(obj)
            value = obj.IpNode.Port;
        end
        
        function set.Version(obj, version)
            if ~isequal(version, obj.EXPECTED_SERVER_VERSION)
                error(message('raspi:utils:UnexpectedServerVersion', ...
                    obj.EXPECTED_SERVER_VERSION, version));
            end
        end
    end
    
    methods
        function output = system(obj, command, sudo)
            % output = system(rpi, command, sudo) executes the command on
            % the Raspberry Pi hardware and returns the resulting output.
            % If 'sudo' is specified as the third argument, the command is
            % executed as super user.
            validateattributes(command, {'char'}, {'nonempty', 'row'}, ...
                '', 'command');
            if nargin > 2
                sudo = validatestring(sudo, {'sudo'}, '', 'sudo');
                sudo = [sudo, ' '];
            else
                sudo = '';
            end
            
            % Execute command on the remote host using SSH
            try
                output = obj.Ssh.executeCommand([sudo, command]);
            catch ME
                throwAsCaller(ME);
            end
        end
        
        function deleteFile(obj, fileName)
            % deleteFile(rpi, fileName) deletes the file with name fileName
            % on the Raspberry Pi hardware.
            validateattributes(fileName, {'char'}, {'nonempty', 'row'}, ...
                '', 'fileName');
            
            % Delete file on the remote host
            try
                executeCommand(obj.Ssh,['echo y|rm ' fileName]);
            catch ME
                throwAsCaller(ME);
            end
        end
        
        function getFile(obj, remoteSource, localDestination)
            % getFile(rpi, remoteSource, localDestination) retrieves the file,
            % remoteSource, from Raspberry Pi hardware and copies it to the
            % file localDestination in the host computer.
            validateattributes(remoteSource, {'char'}, {'nonempty', 'row'}, ...
                '', 'remoteSource');
            if nargin < 3
                localDestination = ['"' pwd '"'];
            else
                validateattributes(localDestination, {'char'}, {'nonempty', 'row'}, ...
                '', 'localDestination');
            end
            try
                getFile(obj.Scp, obj.fullLnxFile(remoteSource), ...
                    localDestination);
            catch ME
                throwAsCaller(ME);
            end
        end
        
        function putFile(obj, localSource, remoteDestination)
            % putFile(rpi, localSource, remoteDestination) copies the file,
            % localSource, in the host computer to the file
            % remoteDestination in Raspberry Pi hardware.
            %
            % If the remoteDestination is not specified, the file is copied
            % to the home folder of the user.
            validateattributes(localSource, {'char'}, {'nonempty', 'row'}, ...
                '', 'localSource');
            if nargin > 2
                validateattributes(remoteDestination, {'char'}, ...
                    {'nonempty', 'row'}, ...
                    '', 'remoteDestination');
            else
                remoteDestination = '';
            end
            try
                putFile(obj.Scp, localSource, ...
                    obj.fullLnxFile(remoteDestination));
            catch ME
                throwAsCaller(ME);
            end
        end
        
        function openShell(obj)
            % openShell(rpi) opens an interactive command shell to
            % Raspberry Pi hardware.
            openShell(obj.Ssh);
        end
        
        function ret = scanI2CBus(obj, bus)
            % scanI2CBus(rpi, bus) returns a list of addresses
            % corresponding to devices discovered on the I2C bus.
            %
            % scanI2CBus(rpi) is supported if there is a single available I2C bus.
            
            if nargin < 2
                buses = obj.AvailableI2CBuses;
                if isempty(buses)
                    bus = '';
                else
                    bus = buses{1};
                end
            end
            validateattributes(bus, {'char'}, ...
                {'row','nonempty'}, '', 'bus');
            if ~any(strcmpi(bus, obj.AvailableI2CBuses))
                error(message('raspi:utils:InvalidI2CBus',bus));
            end
            
            id = getId(bus);
            busNumber = obj.I2C.(id).Number;
            output = popen(obj,['sudo i2cdetect -y ', int2str(busNumber)]);
            output = regexprep(output, '\d\d:', '');
            ret = regexp(output, '[abcdefABCDEF0-9]{2,2}', 'match');
            for i = 1:numel(ret)
                ret{i} = ['0x' upper(ret{i})];
            end
        end
        
        function enableSPI(obj)
            % enableSPI(rpi) enables SPI peripheral on the Raspberry Pi
            % hardware.
            try
                popen(obj,'sudo modprobe spidev');
                popen(obj,'sudo modprobe spi_bcm2708');
                pause(1);
                output = popen(obj,'cat /proc/modules');         
            catch ME
                baseME = MException(message('raspi:utils:CannotEnableSPI'));
                EX = addCause(baseME, ME);
                throw(EX);
            end
            if isempty(regexp(output, 'spi_bcm2708', 'match'))
                error(message('raspi:utils:CannotEnableSPI'));
            end
            getAvailablePeripherals(obj);
        end
        
        function disableSPI(obj)
            % disableSPI(rpi) disables SPI peripheral on the Raspberry Pi
            % hardware.
            try
                popen(obj,'sudo modprobe -r spi_bcm2708');
                pause(1);
                output = popen(obj,'cat /proc/modules');         
            catch ME
                baseME = MException(message('raspi:utils:CannotEnableSPI'));
                EX = addCause(baseME, ME);
                throw(EX);
            end
            if ~isempty(regexp(output, 'spi_bcm2708', 'match'))
                error(message('raspi:utils:CannotDisableSPI'));
            end
            getAvailablePeripherals(obj);
        end
        
        function enableI2C(obj, speed)
            % enableI2C(rpi) enables I2C peripheral on the Raspberry Pi
            % hardware.
            if nargin < 2
                speed = 100000;
            else
                validateattributes(speed, {'numeric'}, ...
                    {'scalar','nonzero','nonnan'}, '', 'speed');
            end
            try
                popen(obj,'sudo modprobe i2c_dev');
                popen(obj,sprintf('sudo modprobe i2c_bcm2708 baudrate=%d', speed));
                pause(1);
                output = popen(obj,'cat /proc/modules');
            catch ME
                baseME = MException(message('raspi:utils:CannotEnableI2C'));
                EX = addCause(baseME, ME);
                throw(EX);
            end
            if isempty(regexp(output, 'i2c_bcm2708', 'match'))
                error(message('raspi:utils:CannotEnableI2C'));
            end
            getAvailablePeripherals(obj);
        end
        
        function disableI2C(obj)
            % disableI2C(rpi) disables I2C peripheral on the Raspberry Pi
            % hardware.
            try
                popen(obj,'sudo modprobe -r i2c_dev');
                popen(obj,'sudo modprobe -r i2c_bcm2708');
                pause(1);
                output = popen(obj,'cat /proc/modules');
            catch ME
                baseME = MException(message('raspi:utils:CannotDisableI2C'));
                EX = addCause(baseME, ME);
                throw(EX);
            end
            if ~isempty(regexp(output, 'i2c_bcm2708', 'match'))
                error(message('raspi:utils:CannotDisableI2C'));
            end
            getAvailablePeripherals(obj);
        end
        
        function showPins(obj)
            % showPins(rpi) shows a diagram of user accessible pins.
            showImage(obj.BoardInfo.GPIOImgFile, ...
                [obj.BoardName ': Pin Map']);
        end
        
        % LED interface
        function showLEDs(obj)
            % showLEDs(rpi) shows locations of user accessible LED's.
            showImage(obj.BoardInfo.LEDImgFile, ...
                [obj.BoardName ': LED Locations']);
        end
        
        function writeLED(obj, led, value)
            % writeLED(rpi, led, value) sets the led state to the given value.
            led = validatestring(led, obj.AvailableLEDs);
            validateattributes(value, {'numeric', 'logical'}, ...
                {'scalar'}, '', 'value');
            if isnumeric(value) && ~((value == 0) || (value == 1))
                error(message('raspi:utils:InvalidLEDValue'));
            end
            id = getId(led);
            if ~isequal(obj.LED.(id).Trigger, 'none')
                configureLED(obj, led, 'none');
            end
            
            % Send an LED write request
            sendRequest(obj,obj.REQUEST_LED_WRITE, ...
                uint32(obj.LED.(id).Number), logical(value));
            recvResponse(obj);
        end
        
        % GPIO interface
        function pinMode = configureDigitalPin(obj, pinNumber, pinMode)
            % configureDigitalPin(rpi, pinNumber, pinMode)
            warning(message('raspi:utils:DeprecateConfigureDigitalPin'));
            checkDigitalPin(obj, pinNumber);
            if nargin == 2
                % Return current pin configuration
                pinName = getPinName(pinNumber);
                pinMode = obj.PINMODESTR{obj.DigitalPin.(pinName).Direction + 1};
            elseif nargin == 3
                % Configure pin for desired mode
                pinMode = validatestring(pinMode, {'input', 'output'});
                if isequal(pinMode, 'input')
                    direction = obj.GPIO_INPUT;
                else
                    direction = obj.GPIO_OUTPUT;
                end
            
                % Send a message to the server to configure pin
                sendRequest(obj, ...
                    obj.REQUEST_GPIO_INIT, ...
                    uint32(pinNumber), ...
                    uint8(direction));
                recvResponse(obj);
                
                % Cache pin configuration
                pinName = getPinName(pinNumber);
                obj.DigitalPin.(pinName).Opened = true;
                obj.DigitalPin.(pinName).Direction = direction;
                pinMode = obj.PINMODESTR{direction + 1};
            end
        end
        
        function pinMode = configurePin(obj, pinNumber, pinMode)
            % configurePin(rpi, pinNumber, pinMode)
            
            checkDigitalPin(obj, pinNumber);
            if nargin == 2
                % Return current pin configuration
                pinName = getPinName(pinNumber);
                pinMode = obj.UPINMODESTR{obj.DigitalPin.(pinName).Direction + 1};
            elseif nargin == 3
                % Configure pin for desired mode
                pinMode = validatestring(pinMode, obj.UPINMODESTR(1:2));
                if isequal(pinMode,obj.UPINMODESTR{1})
                    direction = obj.GPIO_INPUT;
                else
                    direction = obj.GPIO_OUTPUT;
                end
            
                % Send a message to the server to configure pin
                sendRequest(obj, ...
                    obj.REQUEST_GPIO_INIT, ...
                    uint32(pinNumber), ...
                    uint8(direction));
                recvResponse(obj);
                
                % Cache pin configuration
                pinName = getPinName(pinNumber);
                obj.DigitalPin.(pinName).Opened = true;
                obj.DigitalPin.(pinName).Direction = direction;
                pinMode = obj.UPINMODESTR{direction + 1};
            end
        end
        
        function pinMode = getDigitalPinConfiguration(obj, pinNumber)
            % pinMode = getDigitalPinConfiguration(rpi, pinNumber) returns
            % the current configuration of the specified digital pin.
            checkDigitalPin(obj, pinNumber);
            pinName = getPinName(pinNumber);
            pinMode = obj.PINMODESTR{obj.DigitalPin.(pinName).Direction + 1};
        end
        
        function value = readDigitalPin(obj, pinNumber)
            % value = readDigitalPin(rpi, pinNumber) reads the logical
            % state of the specified digital pin.
            checkDigitalPin(obj, pinNumber);
            pinName = getPinName(pinNumber);
            if ~obj.DigitalPin.(pinName).Opened
                configurePin(obj, pinNumber, 'DigitalInput');
            end
            if obj.DigitalPin.(pinName).Direction ~= obj.GPIO_INPUT
                error(message('raspi:utils:InvalidDigitalRead', pinNumber));
            end
            
            % Send read request
            sendRequest(obj,obj.REQUEST_GPIO_READ, uint32(pinNumber));
            value = logical(recvResponse(obj));
        end
        
        function writeDigitalPin(obj, pinNumber, value)
            % writeDigitalPin(rpi, pinNumber, value) sets the state of a
            % digital pin to the given value.
            checkDigitalPin(obj,pinNumber);
            checkDigitalValue(value);
            pinName = getPinName(pinNumber);
            if ~obj.DigitalPin.(pinName).Opened
                configurePin(obj, pinNumber, 'DigitalOutput');
            end
            if obj.DigitalPin.(pinName).Direction ~= obj.GPIO_OUTPUT
                error(message('raspi:utils:InvalidDigitalWrite', pinNumber));
            end
            
            % Send write request
            sendRequest(obj,obj.REQUEST_GPIO_WRITE, uint32(pinNumber), ...
                logical(value));
            recvResponse(obj);
        end
        
        % I2C interface
        function i2cObj = i2cdev(obj, varargin)
            i2cObj = raspi.internal.i2cdev(obj, varargin{:});
        end
        
        % SPI interface
        function spiObj = spidev(obj, varargin)
            spiObj = raspi.internal.spidev(obj, varargin{:});
        end
        
        % Serial interface
        function serialObj = serialdev(obj, varargin)
            serialObj = raspi.internal.serialdev(obj, varargin{:});
        end
        
        % CameraBoard interface
        function camObj = cameraboard(obj, varargin)
            camObj = raspi.internal.cameraboard(obj, varargin{:});
        end
    end
    
    methods (Hidden)
        function sendRequest(obj, requestId, varargin)
            %sendRequest Send request to hardware.
            obj.Sequence = obj.Sequence + 1;
            req = createRequest(obj, requestId, varargin{:});
            send(obj.Tcp, req);
        end
        
        function [data,err] = recvResponse(obj)
            %recvResponse Return response from hardware.
            %   [DATA,ERR] = recvResponse(obj) returns DATA error status
            %   ERR from hardware.
            
            data = [];
            resp = [];
            while isempty(resp) || resp(2) ~= obj.Sequence
                resp = receive(obj.Tcp, ...
                    obj.RESP_HEADER_SIZE, ...
                    obj.RESP_HEADER_PRECISION);
                if resp(1) == 0
                    data = receive(obj.Tcp,resp(3),'uint8');
                end
            end
            % We have desired sequence #
            err = resp(1);
            if err ~= 0 && nargout < 2
                throw(getServerException(err))
            end
        end
        
        function systemCmd(obj, cmd)
            %systemCmd Execute system call on the hardware.
            sendRequest(obj,obj.REQUEST_SYSTEM_SYSTEM, uint8(cmd));
            recvResponse(obj);
        end
        
        function output = popen(obj, cmd)
            % output = popen(obj, cmd) Execute a popen call on the target.
            sendRequest(obj,obj.REQUEST_SYSTEM_POPEN, uint8(cmd));
            [output,errno] = recvResponse(obj);
            if errno ~= 0
                error(message('raspi:utils:PopenError', errno));
            end
            output = char(output);
        end
        
        function config = getAvailableLEDConfigurations(obj, led)
            % config = getAvailableLEDConfigurations(obj, led) returns
            % available LED configurations.
            led = validatestring(led, obj.AvailableLEDs);
            id = getId(led);
            sendRequest(obj,obj.REQUEST_LED_GET_TRIGGER, ...
                uint32(obj.LED.(id).Number));
            payload = strtrim(char(recvResponse(obj)));
            payload = regexprep(payload, '\[|\]', '');
            config = regexp(payload, '\s+', 'split');
        end
        
        function trigger = getLEDConfiguration(obj, led)
            % trigger = getLEDConfiguration(obj, led) returns current LED
            % configuration.
            led = validatestring(led, obj.AvailableLEDs);
            id = getId(led);
            sendRequest(obj,obj.REQUEST_LED_GET_TRIGGER, ...
                uint32(obj.LED.(id).Number));
            payload = recvResponse(obj);
            ret     = regexp(char(payload), '\[(.+)]', 'tokens', 'once');
            trigger = ret{1};
        end
        
        function configureLED(obj, led, trigger)
            %configureLED(obj, led, trigger) configures LED trigger.
            led = validatestring(led, obj.AvailableLEDs);
            id = getId(led);
            trigger = validatestring(trigger, ...
                obj.LED.(id).AvailableTriggers, '', 'trigger');
            
            % Send a set request for LED trigger
            sendRequest(obj,obj.REQUEST_LED_SET_TRIGGER, ...
                uint32(obj.LED.(id).Number), trigger);
            recvResponse(obj);
            
            % Change trigger state
            obj.LED.(id).Trigger = trigger;
        end
    end
    
    methods (Access = protected)
        function s = getFooter(obj) %#ok<MANU>
            s = sprintf(['  <a href="matlab:raspi.internal.helpView', ...
                '(''raspberrypiio'',''RaspiSupportedPeripherals'')">', ...
                'Supported peripherals</a>\n']);
        end
        
        function req = createRequest(obj, requestId, varargin)
            payload = uint8([]);
            if nargin > 0
                for i = 1:nargin-2
                    if ismember(class(varargin{i}),{'char', 'logical'})
                        payload = [payload, uint8(varargin{i})]; %#ok<AGROW>
                    else
                        payload = [payload, typecast(varargin{i}, 'uint8')]; %#ok<AGROW>
                    end
                end
            end
            req = [uint32(requestId), uint32(obj.Sequence), ...
                uint32(length(payload))];
            req = [typecast(req, 'uint8'), payload];
        end
        
        function status = getGPIOPinStatus(obj, pinNumber)
            sendRequest(obj,obj.REQUEST_GPIO_GET_DIRECTION, ...
                uint32(pinNumber));
            resp = recvResponse(obj); % uint8
            status = uint8(resp);
        end
        
        function getAvailablePeripherals(obj)
            %Find available I2C buses
            obj.AvailableI2CBuses = {};
            for i = 1:length(obj.BoardInfo.I2C)
                if obj.isI2CBusAvailable(obj.BoardInfo.I2C(i).Number)
                    obj.AvailableI2CBuses{end+1} = obj.BoardInfo.I2C(i).Name;
                    id = getId(obj.BoardInfo.I2C(i).Name);
                    obj.I2C.(id).Number = obj.BoardInfo.I2C(i).Number;
                    obj.I2C.(id).Pins   = obj.BoardInfo.I2C(i).Pins;
                end
            end
            if ~isempty(obj.AvailableI2CBuses)
                % Find I2C bus speed
                try
                    ret = popen(obj,'sudo cat /sys/module/i2c_bcm2708/parameters/baudrate');
                    obj.I2CBusSpeed = str2double(ret);
                catch ME
                    baseME = MException(message('raspi:utils:CannotGetI2CBusSpeed'));
                    EX = addCause(baseME, ME);
                    warning(EX.identifier, EX.message);
                end
            end
            
            % Find available SPI channels
            obj.AvailableSPIChannels = {};
            obj.SPI(1).Pins = [];
            for i = 1:length(obj.BoardInfo.SPI(1).Channel)
                if isSPIChannelAvailable(obj,obj.BoardInfo.SPI(1).Number, ...
                        obj.BoardInfo.SPI(1).Channel(i).Number)
                    obj.AvailableSPIChannels{end+1} = obj.BoardInfo.SPI(1).Channel(i).Name;
                    id = getId(obj.BoardInfo.SPI(1).Channel(i).Name);
                    obj.SPI(1).Channel.(id).Number = obj.BoardInfo.SPI(1).Channel(i).Number;
                    obj.SPI(1).Channel.(id).Pins   = obj.BoardInfo.SPI(1).Channel(i).Pins;
                end
            end
            if ~isempty(obj.AvailableSPIChannels)
                obj.SPI(1).Pins = obj.BoardInfo.SPI(1).Pins;
            end
            
            % Remove I2C pins from the list of available GPIO pins
            obj.AvailableDigitalPins = obj.BoardInfo.GPIOPins;
            for i = 1:length(obj.AvailableI2CBuses)
                id = getId(obj.AvailableI2CBuses{i});
                obj.AvailableDigitalPins = ...
                            setdiff(obj.AvailableDigitalPins, ...
                            obj.I2C.(id).Pins);
            end
            
            % Remove SPI pins from the list of available GPIO pins
            obj.AvailableDigitalPins = setdiff(obj.AvailableDigitalPins, ...
                obj.SPI(1).Pins);
            for i = 1:length(obj.AvailableSPIChannels)
                id = getId(obj.AvailableSPIChannels{i});
                obj.AvailableDigitalPins = ...
                    setdiff(obj.AvailableDigitalPins, ...
                    obj.SPI.Channel.(id).Pins);
            end
            
            % Get current state of GPIO pins
            for pin = obj.AvailableDigitalPins
                status = getGPIOPinStatus(obj, pin);
                if status ~= obj.GPIO_DIRECTION_NA
                    pinName = getPinName(pin);
                    obj.DigitalPin.(pinName).Opened    = false;
                    obj.DigitalPin.(pinName).Direction = status;
                end
            end
            
            % Set available LED's
            obj.AvailableLEDs = {};
            for i = 1:numel(obj.BoardInfo.LED)
                name = obj.BoardInfo.LED(i).Name;
                id = getId(name);
                obj.AvailableLEDs{end+1} = name;
                obj.LED.(id).Number            = i - 1;
                obj.LED.(id).Color             = obj.BoardInfo.LED(i).Color;
                obj.LED.(id).Trigger           = getLEDConfiguration(obj,name);
                obj.LED.(id).AvailableTriggers = getAvailableLEDConfigurations(obj,name);
            end
        end
        
        function checkDigitalPin(obj, pinNumber)
            validateattributes(pinNumber, {'numeric'}, {'scalar'}, ...
                '', 'pinNumber');
            if ~any(obj.AvailableDigitalPins == pinNumber)
                error(message('raspi:utils:UnexpectedDigitalPinNumber'));
            end
        end
        
        function closeAllDigitalPins(obj)
            for pinNumber = obj.AvailableDigitalPins
                pinName = getPinName(pinNumber);
                if obj.DigitalPin.(pinName).Opened
                    try
                        sendRequest(obj,obj.REQUEST_GPIO_TERMINATE, ...
                            uint32(pinNumber));
                        recvResponse(obj);
                    catch EX
                        warning(EX.identifier, EX.message);
                    end
                end
            end
        end
        
        function output = echo(obj, input)
            sendRequest(obj, obj.REQUEST_ECHO, uint8(input));
            output = recvResponse(obj); % uint8
        end
        
        function version = getServerVersion(obj)
            sendRequest(obj, obj.REQUEST_VERSION);
            version = typecast(recvResponse(obj), 'uint32'); % uint8
        end

        function authorize(obj, hash)
            obj.sendRequest(obj.REQUEST_AUTHORIZATION, [hash, 0]);
            obj.recvResponse;
        end
        
        function ret = isI2CBusAvailable(obj, bus)
            sendRequest(obj, obj.REQUEST_I2C_BUS_AVAILABLE, uint32(bus));
            ret = logical(recvResponse(obj)); % uint8
        end
        
        function ret = isSPIChannelAvailable(obj, spi, channel)
            try
                popen(obj, ['stat /dev/spidev', int2str(spi), '.', int2str(channel)]);
                ret = true;
            catch 
                ret = false;
            end
        end
        
        function name = getBoardName(obj)
            %  http://elinux.org/RPi_HardwareHistory
            %  0000 - Beta board
            %  0001 - Not used
            %  0002 - Model B Rev 1
            %  0003 - Model B Rev 1
            %  0004 - Model B Rev 2 
            %  0005 - Model B Rev 2 
            %  0006 - Model B Rev 2
            %  0007 - Model A Rev 2
            %  0008 - Model A Rev 2
            %  0009 - Model A Rev 2
            %  0010 - Model B+
            %  0011 - Compute Module
            %  000e - Model B Rev 2 + 512MB
            %  000f - Model B Rev 2 + 512MB
            %  
            %  * 1000 in front of revision indicates overvolting
            try
                ret = popen(obj,'cat /proc/cpuinfo');
                hwId = regexp(ret, 'Hardware\s+:\s+BCM(\d+)\s+','tokens','once');
                if isequal(hwId{1},'2709')
                    % Hardware	: BCM2709
                    name = 'Raspberry Pi 2 Model B';
                    return;
                end
                revno = regexp(ret, 'Revision\s+:\s+([abcdefABCDEF0-9]+)', 'tokens', 'once');
                switch revno{1}(end-3:end)
                    case {'0002','0003'}
                        name = 'Raspberry Pi Model B Rev 1';
                    case {'0007','0008'}
                        name = 'Raspberry Pi Model A Rev 2';
                    case {'0004','0005','0006','0009','000d','000e','000f'}
                        name = 'Raspberry Pi Model B Rev 2';
                    case {'0010','0013'}
                        name = 'Raspberry Pi Model B+';
                    case {'0011'}
                        name = 'Raspberry Pi Compute Module';
                    case {'0012'}
                        name = 'Raspberry Pi Model A+';
                    otherwise
                        % early unknown beta board
                        name = 'Raspberry Pi Model B Rev 1';
                end
            catch EX
                error(message('raspi:utils:BoardRevision'));
            end
        end
    end
    
    methods (Hidden)
        function delete(obj)
            if obj.Initialized
                if ~isempty(obj.IpNode) && isKey(obj.ConnectionMap, obj.IpNode.Hostname)
                    remove(obj.ConnectionMap, obj.IpNode.Hostname);
                end
                % Don't need to worry about LED. LED is opened/closed at each
                % write.
                try
                    closeAllDigitalPins(obj);
                catch EX
                    warning(EX.identifier, EX.message);
                end
            end
        end
        
        function saveInfo = saveobj(obj)
            saveInfo.DeviceAddress = obj.DeviceAddress; 
        end
    end
    
    methods (Static, Access = protected)
        function file = fullLnxFile(varargin)
            % Convert paths to Linux convention.
            
            file = strrep(varargin{1}, '\', '/');
            for i = 2:nargin
                file = [file, '/', varargin{i}]; %#ok<AGROW>
            end
            file = strrep(file, '//', '/');
            file = regexprep(file, '/$', '');  %remove trailing slash
        end
    end
    
    methods (Static, Hidden)
        function obj = loadobj(saveInfo)
            try
                obj = raspi(saveInfo.DeviceAddress);
            catch EX
                warning(EX.identifier, EX.message);
                obj = raspi.empty;
            end
        end
    end
end

% ----------------------
% Local Functions
% ----------------------

function showImage(imgFile, title)
if ~isempty(imgFile) && exist(imgFile,'file') == 2
    fig = figure( ...
        'Name', title, ...
        'NumberTitle', 'off');
    hax = axes( ...
        'Parent',fig, ...
        'Visible','off');
    image(imread(imgFile),'parent',hax);
    set(hax, 'LooseInset', get(hax, 'TightInset'));
    set(fig, 'Name', title, 'NumberTitle', 'off');
    axis('off');
    axis('equal')
end
end

function id = getId(name)
id = regexprep(name, '[^\w]', '');
end

function pinName = getPinName(pinNumber)
pinName = ['gpio' int2str(pinNumber)];
end

function EX = getServerException(errno)
try
    EX = MException(message(['raspi:server:ERRNO', num2str(errno)]));
catch
    EX = MException(message('raspi:server:ERRNO'));
end
end

function checkDigitalValue(value)
validateattributes(value, {'numeric', 'logical'}, ...
    {'scalar'}, '', 'value');
if isnumeric(value) && ~((value == 0) || (value == 1))
    error(message('raspi:utils:InvalidDigitalInputValue'));
end
end
