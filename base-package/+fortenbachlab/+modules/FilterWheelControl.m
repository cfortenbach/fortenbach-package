classdef FilterWheelControl < symphonyui.ui.Module
    % UI module for controlling the Thorlabs FW102C ND filter wheel and
    % displaying estimated photon flux based on LED calibration data.
    %
    % The module provides:
    %   - NDF position selector (dropdown)
    %   - Display of max photon flux (photons/cm2/s) at NDF 0 and current NDF
    %
    % Calibration data is loaded from a text file in calibration-resources.

    properties (Access = private)
        log
        settings
        filterWheel
        ndfPopup                % Popup menu for NDF selection
        ndfValues               % Numeric NDF values corresponding to popup items
        maxFluxText             % Display: max flux at NDF 0
        currentFluxText         % Display: max flux at current NDF
        calibrationVoltage      % Voltage column from calibration file
        calibrationFlux         % Photons/cm2/s column from calibration file
    end

    methods

        function obj = FilterWheelControl()
            try
                obj.log = log4m.LogManager.getLogger(class(obj));
            catch
                obj.log = [];
            end
            obj.settings = fortenbachlab.modules.settings.FilterWheelControlSettingsCF();
        end

        function createUi(obj, figureHandle)
            % Center the window on screen.
            screenSize = get(0, 'ScreenSize');
            w = 320; h = 120;
            x = round((screenSize(3) - w) / 2);
            y = round((screenSize(4) - h) / 2);

            set(figureHandle, ...
                'Name', 'Filter Wheel & Calibration', ...
                'Position', [x y w h]);

            pad = 11;
            labelW = 130;
            ctrlW = w - 2*pad - labelW - 7;

            % Row 1: NDF selector
            uicontrol(figureHandle, 'Style', 'text', ...
                'String', 'NDF:', ...
                'HorizontalAlignment', 'left', ...
                'Units', 'pixels', ...
                'Position', [pad 80 labelW 20]);

            obj.ndfPopup = uicontrol(figureHandle, 'Style', 'popupmenu', ...
                'String', {'0.0', '0.5', '1.0', '2.0', '3.0', '4.0'}, ...
                'Units', 'pixels', ...
                'Position', [pad + labelW + 7, 80, ctrlW, 22], ...
                'Callback', @obj.onSelectedNdfSetting);
            obj.ndfValues = [0.0, 0.5, 1.0, 2.0, 3.0, 4.0];

            % Row 2: Max flux at NDF 0
            uicontrol(figureHandle, 'Style', 'text', ...
                'String', 'Max flux (NDF 0):', ...
                'HorizontalAlignment', 'left', ...
                'Units', 'pixels', ...
                'Position', [pad 53 labelW 20]);

            obj.maxFluxText = uicontrol(figureHandle, 'Style', 'text', ...
                'String', '-- photons/cm2/s', ...
                'HorizontalAlignment', 'left', ...
                'Units', 'pixels', ...
                'Position', [pad + labelW + 7, 53, ctrlW, 20]);

            % Row 3: Max flux at current NDF
            uicontrol(figureHandle, 'Style', 'text', ...
                'String', 'Max flux (current NDF):', ...
                'HorizontalAlignment', 'left', ...
                'Units', 'pixels', ...
                'Position', [pad 26 labelW 20]);

            obj.currentFluxText = uicontrol(figureHandle, 'Style', 'text', ...
                'String', '-- photons/cm2/s', ...
                'HorizontalAlignment', 'left', ...
                'Units', 'pixels', ...
                'Position', [pad + labelW + 7, 26, ctrlW, 20]);
        end

    end

    methods (Access = protected)

        function willGo(obj)
            devices = obj.configurationService.getDevices('FilterWheel');
            if isempty(devices)
                error('No FilterWheel device found');
            end

            obj.filterWheel = devices{1};

            % Load calibration data.
            obj.loadCalibration();

            % Log what the device currently thinks NDF is.
            try
                ndfBefore = obj.filterWheel.getConfigurationSetting('NDF');
                obj.logInfo(sprintf('FilterWheel NDF setting at module load: %g', ndfBefore));
            catch
            end

            % Force NDF to 0.0 on startup.
            targetNDF = 0.0;
            try
                obj.filterWheel.setNDF(targetNDF);
            catch e
                obj.logWarn(['Filter wheel setNDF failed: ' e.message]);
            end
            try
                obj.filterWheel.setReadOnlyConfigurationSetting('NDF', targetNDF);
            catch
            end

            % Set the popup to match (index 1 = NDF 0.0).
            set(obj.ndfPopup, 'Value', 1);

            % Update the flux display.
            obj.updateFluxDisplay(targetNDF);

            try
                obj.loadSettings();
            catch x
                obj.logDebug(['Failed to load settings: ' x.message]);
            end
        end

        function willStop(obj)
            try
                obj.saveSettings();
            catch x
                obj.logDebug(['Failed to save settings: ' x.message]);
            end
        end

    end

    methods (Access = private)

        function ndf = getSelectedNdf(obj)
            idx = get(obj.ndfPopup, 'Value');
            ndf = obj.ndfValues(idx);
        end

        function onSelectedNdfSetting(obj, ~, ~)
            ndf = obj.getSelectedNdf();

            % Check if this is actually a change.
            try
                previousNDF = obj.filterWheel.getConfigurationSetting('NDF');
            catch
                previousNDF = [];
            end
            try
                obj.filterWheel.setNDF(ndf);
            catch e
                try
                    obj.filterWheel.setReadOnlyConfigurationSetting('NDF', ndf);
                catch
                end
                obj.logWarn(['Filter wheel command failed: ' e.message]);
            end
            try
                obj.filterWheel.setReadOnlyConfigurationSetting('NDF', ndf);
            catch
            end
            obj.updateFluxDisplay(ndf);
            % Wait for the filter wheel to physically settle.
            if ~isempty(previousNDF) && ~isequal(previousNDF, ndf)
                pause(4);
            end
        end

        function loadCalibration(obj)
            calibFile = '';

            try
                calibFile = fortenbachlab.Package.getCalibrationResource( ...
                    'rigs', 'fortenbach', 'led_455nm_calibration.txt');
                if ~exist(calibFile, 'file')
                    calibFile = '';
                end
            catch
                calibFile = '';
            end

            if isempty(calibFile)
                obj.logWarn('LED calibration file not found. Using default values.');
                obj.calibrationVoltage = [0; 0.1; 0.5; 1.0; 3.0; 5.0; 8.0; 10.0];
                obj.calibrationFlux    = [0; 9.05e14; 4.68e15; 9.18e15; 2.55e16; 4.01e16; 5.99e16; 7.23e16];
                return;
            end

            fid = fopen(calibFile, 'r');
            voltages = [];
            fluxes = [];
            while ~feof(fid)
                line = fgetl(fid);
                if isempty(line) || line(1) == '%'
                    continue;
                end
                vals = sscanf(line, '%f\t%f');
                if numel(vals) == 2
                    voltages(end+1) = vals(1); %#ok<AGROW>
                    fluxes(end+1) = vals(2);   %#ok<AGROW>
                end
            end
            fclose(fid);

            obj.calibrationVoltage = voltages(:);
            obj.calibrationFlux = fluxes(:);
        end

        function flux = getFluxAtVoltage(obj, voltage, ndf)
            if voltage <= 0
                flux = 0;
                return;
            end
            voltage = min(voltage, max(obj.calibrationVoltage));
            fluxNdf0 = interp1(obj.calibrationVoltage, obj.calibrationFlux, voltage, 'pchip');
            flux = fluxNdf0 / (10^ndf);
        end

        function updateFluxDisplay(obj, ndf)
            if nargin < 2 || isempty(ndf)
                ndf = obj.getSelectedNdf();
            end
            if isempty(ndf) || ~isnumeric(ndf)
                ndf = 0;
            end

            if isempty(obj.calibrationFlux)
                return;
            end

            maxFluxNdf0 = obj.calibrationFlux(end);
            maxFluxCurrentNdf = maxFluxNdf0 / (10^ndf);

            set(obj.maxFluxText, 'String', ...
                [obj.formatScientific(maxFluxNdf0), ' photons/cm2/s']);
            set(obj.currentFluxText, 'String', ...
                [obj.formatScientific(maxFluxCurrentNdf), ' photons/cm2/s (NDF ', num2str(ndf), ')']);
            drawnow;
        end

        function loadSettings(obj)
            if ~isempty(obj.settings.viewPosition)
                p1 = obj.view.position;
                p2 = obj.settings.viewPosition;
                obj.view.position = [p2(1) p2(2) p1(3) p1(4)];
            end
        end

        function saveSettings(obj)
            obj.settings.viewPosition = obj.view.position;
            obj.settings.save();
        end

        % Logging helpers (safe if log4m is unavailable)
        function logInfo(obj, msg)
            if ~isempty(obj.log), obj.log.info(msg); end
        end
        function logWarn(obj, msg)
            if ~isempty(obj.log), obj.log.warn(msg); end
        end
        function logDebug(obj, msg)
            if ~isempty(obj.log), obj.log.debug(msg); end
        end

    end

    methods (Static)
        function str = formatScientific(num)
            if num == 0
                str = '0';
            else
                exponent = floor(log10(abs(num)));
                mantissa = num / 10^exponent;
                str = sprintf('%.2fe+%02d', mantissa, exponent);
            end
        end
    end

end
