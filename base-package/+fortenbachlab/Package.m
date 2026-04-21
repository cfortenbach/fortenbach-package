classdef Package < handle
    % Package  Provides paths to calibration resources and shared data for
    % the fortenbachlab Symphony package.
    %
    % Usage:
    %   p = fortenbachlab.Package.getCalibrationResource('rigs', 'fortenbach', 'led_455nm_calibration.txt');
    %   data = importdata(p);

    methods (Static)

        function p = getCalibrationResource(varargin)
            % GETCALIBRATIONRESOURCE  Return the full path to a calibration file.
            %
            %   p = fortenbachlab.Package.getCalibrationResource('rigs', 'fortenbach', 'myfile.txt')
            %
            % The calibration-resources directory is expected as a sibling
            % to base-package inside fortenbach-package/:
            %   fortenbach-package/
            %     calibration-resources/rigs/fortenbach/...
            %     base-package/+fortenbachlab/Package.m  <-- this file

            % Navigate: Package.m -> +fortenbachlab -> base-package -> fortenbach-package
            parentPath = fileparts(fileparts(fileparts(mfilename('fullpath'))));
            calibrationPath = fullfile(parentPath, 'calibration-resources');

            if ~exist(calibrationPath, 'dir')
                error('fortenbachlab:Package:noCalibrationDir', ...
                    ['Cannot find calibration-resources directory. Expected: ' calibrationPath]);
            end

            p = fullfile(calibrationPath, varargin{:});
        end

    end

end
