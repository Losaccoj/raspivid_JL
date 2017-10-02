clear all;
close all;
ffmpegDir = 'C:\ffmpeg';
raspividJL=1;
[FileName,PathName] = uiputfile('*.dg','Select .dg file to save data');
outName=[PathName,FileName];
Filestr=FileName(1:end-3);
% mypi = raspi('olfactorypi.ucdenver.pvt','pi','stink100');
mypi = raspi;
mycam = cameraboard(mypi,'Resolution','800x600','FrameRate',60);
    % Use cameraboard(mypi) to get available options
    
    if raspividJL == 1
        record(mycam,Filestr,99999);
        while mycam.Recording == 1
            %End recording questdlg
            choice = questdlg('End recording?','End recording?','All','Video','None','None');
            
            %Handle response
            switch choice
                case 'All'
                    stopBehRec(ffmpegDir, Filestr, mycam, mypi);
                    error('user stopped draqaa')
                case 'Video'
                    if raspividJL == 1
                        stopBehRec(ffmpegDir, Filestr, mycam, mypi);
                        %                 stop(mycam)
                        %                 pause(15)
                        %                 getFile(mypi,Filestr,'C:\')
                        %                 deleteFile(mypi,Filestr)
                        %                 movefile(['C:\',Filestr],['C:\',Filestr,'.h264']);
                        %                 cmd = ['"',fullfile(ffmpegDir, 'bin', 'ffmpeg.exe'),'" -loglevel quiet -r 30 -i C:\',Filestr,'.h264 -vcodec copy -flags +global_header C:\',Filestr,'.mp4'];
                        %                 [status, message] = system(cmd);
                        %                 delete(['C:\',Filestr,'.h264']);
                        %                 movefile(['C:\',Filestr,'.mp4'],['C:\Documents and Settings\diego restrepo\Desktop\Justin\',Filestr,'.mp4']);
                    else
                        return
                    end
                case 'None'
                    return
            end
        end
    end
    
pause(15)
getFile(mypi,Filestr,'C:\')
%     %To free space, delete video from piboard
deleteFile(mypi,Filestr)
movefile(['C:\',Filestr],['C:\',Filestr,'.h264']);

cmd = ['"',fullfile(ffmpegDir, 'bin', 'ffmpeg.exe'),'" -loglevel quiet -r 30 -i C:\',Filestr,'.h264 -vcodec copy -flags +global_header C:\',Filestr,'.mp4'];
[status, message] = system(cmd);
% cmd = ['"' fullfile(ffmpegDir, 'bin', 'ffmpeg.exe') '" -loglevel quiet -r 30 -i C:\Filestr.h264 -vcodec copy -flags +global_header C:\Filestr.mp4'];
% [status, message] = system(cmd);
%To prevent ffmpeg error, incl the following in the cmd between copy and
%filename
    %-flags +global_header
delete(['C:\',Filestr,'.h264']);

movefile(['C:\',Filestr,'.mp4'],['C:\Documents and Settings\diego restrepo\Desktop\Justin\',Filestr,'.mp4']);
%cam.Brightness = 70. 
%cam.ExposureMode='night'

clc

