function [] = stopBehRec(ffmpegDir, Filestr, mycam, mypi)
%STOPBEHREC Summary of this function goes here
%   Detailed explanation goes here
stop(mycam)
pause(3)
getFile(mypi,Filestr,'C:\Users\Behavior\Desktop\Justin\')
deleteFile(mypi,Filestr)
movefile(['C:\Users\Behavior\Desktop\Justin\',Filestr],['C:\Users\Behavior\Desktop\Justin\',Filestr,'.h264']);
cmd = ['"',fullfile(ffmpegDir, 'bin', 'ffmpeg.exe'),'" -loglevel quiet -r 30 -i C:\Users\Behavior\Desktop\Justin\',Filestr,'.h264 -vcodec copy -flags +global_header C:\Users\Behavior\Desktop\Justin\',Filestr,'.mp4'];
[status, message] = system(cmd);
delete(['C:\Users\Behavior\Desktop\Justin\',Filestr,'.h264']);

 clear mycam
 clear mypi
 clear raspividJL
 clear ffmpegDir
end

