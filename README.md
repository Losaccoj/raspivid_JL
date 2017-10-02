# raspivid_JL

This code (raspivid_JL) is executable in Matlab and uses the raspicam to capture video. It depends upon ffmpeg, so set that up first. After video capture is ended, it moves the file to the host computer, deletes it from the Pi (to save space), and transcodes it to *.mp4 format. 
I would like to add TTL triggers and frame-based annotations dependent upon analog signal inputs for my application, which is behavioral recording of mice performing an olfactory discrimination task. 
