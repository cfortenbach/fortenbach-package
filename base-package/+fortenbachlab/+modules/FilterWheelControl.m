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
        ndfSettingPopupMenu
        maxFluxText          % Display: max flux at NDF 0
        currentFluxText      % Display: max flux at current NDF
        currentNdfText       % Display: current NDF value
        calibrationVoltage   % Voltage column from calibration file
        calibrationFlux      % Photons/cm2/s column from calibration file
    end

    methods

        function obj = FilterWheelControl()
            obj.log = log4m.LogManager.getLogger(class(obj));
            obj.settings = fortenbachlab.modules.settings.FilterWheelControlSettingsCF();
        end

        function createUi(obj, figureHandle)
            import appbox.*;

            set(figureHandle, ...
                'Name', 'Filter Wheel & Calibration', ...
                'Position', screenCenter(280, 120));

            mainLayout = uix.HBox( ...
                'Parent', figureHandle, ...
                'Padding', 11, ...
                'Spacing', 7);

            filterWheelLayout = uix.Grid( ...
                'Parent', mainLayout, ...
                'Spacing', 7);

            % Row labels
            Label( ...
                'Parent', filterWheelLayout, ...
                'String', 'NDF:');
            Label( ...
                'Parent', filterWheelLayout, ...
                'String', 'Max flux (NDF 0):');
            Label( ...
                'Parent', filterWheelLayout, ...
                'String', 'Max flux (current NDF):');

            % Row controls/values
            obj.ndfSettingPopupMenu = MappedPopupMenu( ...
                'Parent', filterWheelLayout, ...
                'String', {' '}, ...
                'HorizontalAlignment', 'left', ...
                'Callback', @obj.onSelectedNdfSetting);

            obj.maxFluxText = uicontrol( ...
                'Parent', filterWheelLayout, ...
                'Style', 'text', ...
                'HorizontalAlignment', 'left', ...
                'String', '-- photons/cm2/s');

            obj.currentFluxText = uicontrol( ...
                'Parent', filterWheelLayout, ...
                'Style', 'text', ...
                'HorizontalAlignment', 'left', ...
                'String', '-- photons/cm2/s');

            set(filterWheelLayout, ...
                'Widths', [120 -1], ...
                'Heights', 23 * ones(1, 3));
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

            % Populate NDF dropdown.
            obj.populateNdfSettingList();

            % Log what the device currently thinks NDF is (for debugging
            % why the UI might default to something other than 4.0).
            try
                ndfBefore = obj.filterWheel.getConfigurationSetting('NDF');
                obj.log.info(sprintf('FilterWheel NDF setting at module load: %g', ndfBefore));
            catch
                ndfBefore = [];
            end

            % Force NDF to 0.0 on startup regardless of any persisted
            % or previous value.
            targetNDF = 0.0;
            try
                obj.filterWheel.setNDF(targetNDF);
            catch e
                obj.log.warn(['Filter wheel setNDF failed: ' e.message]);
            end
            % Ensure the config setting matches even if the serial move
            % raised (so protocols see the intended NDF).
            try
                obj.filterWheel.setReadOnlyConfigurationSetting('NDF', targetNDF);
            catch
            end

            % Set the popup to match. MappedPopupMenu matches the value by
            % equality with one of the entries in 'Values' (not by index).
            try
                set(obj.ndfSettingPopupMenu, 'Value', targetNDF);
            catch e
                obj.log.warn(['Could not set NDF popup to ' num2str(targetNDF) ': ' e.message]);
            end

            % Verify what the popup actually landed on and log it.
            try
                actualVal = get(obj.ndfSettingPopupMenu, 'Value');
                if iscell(actualVal), actualVal = actualVal{1}; end
                obj.log.info(sprintf('NDF popup initialized to: %g', actualVal));
            catch
                actualVal = targetNDF;
            end

            % Update the flux display using the popup's actual value.
            obj.updateFluxDisplay(actualVal);

            try
                obj.loadSettings();
            catch x
                obj.log.debug(['Failed to load settings: ' x.message], x);
            end
        end

        function willStop(obj)
            try
                obj.saveSettings();
            catch x
                obj.log.debug(['Failed to save settings: ' x.message], x);
            end
        end

    end

    methods (Access = private)

        function populateNdfSettingList(obj)
            ndfNums = {0.0, 0.5, 1.0, 2.0, 3.0, 4.0};
            ndfs = {'0.0', '0.5', '1.0', '2.0', '3.0', '4.0'};

            set(obj.ndfSettingPopupMenu, 'String', ndfs);
            set(obj.ndfSettingPopupMenu, 'Values', ndfNums);
        end

        function onSelectedNdfSetting(obj, ~, ~)
            ndf = get(obj.ndfSettingPopupMenu, 'Value');
            if iscell(ndf)
                ndf = ndf{1};
            end
            % Check if this is actually a change (so we only pay the
            % settle-time cost when the wheel needs to move).
            try
                previousNDF = obj.filterWheel.getConfigurationSetting('NDF');
            catch
                previousNDF = [];
            end
            try
                obj.filterWheel.setNDF(ndf);
            catch e
                % setNDF may fail to move the wheel but we still want
                % the config setting updated so the UI and protocols
                % reflect the intended NDF.
                try
                    obj.filterWheel.setReadOnlyConfigurationSetting('NDF', ndf);
                catch
                end
                obj.log.warn(['Filter wheel command failed: ' e.message]);
            end
            % Force the config setting to match the selected NDF regardless
            % of whether the serial command succeeded, so protocols and the
            % flux display always reflect the chosen value.
            try
                obj.filterWheel.setReadOnlyConfigurationSetting('NDF', ndf);
            catch
            end
            obj.updateFluxDisplay(ndf);
            % Wait for the filter wheel to physically settle when NDF
            % actually changed.
            if ~isempty(previousNDF) && ~isequal(previousNDF, ndf)
                pause(4);
            end
        end

        function loadCalibration(obj)
            % Load the LED calibration file via Package resource loader.
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
                obj.log.warn('LED calibration file not found. Using default values.');
                % Default calibration data (455 nm LED, NDF 0, 100 mA/V)
                obj.calibrationVoltage = [0; 0.1; 0.5; 1.0; 3.0; 5.0; 8.0; 10.0];
                obj.calibrationFlux    = [0; 9.05e14; 4.68e15; 9.18e15; 2.55e16; 4.01e16; 5.99e16; 7.23e16];
                return;
            end

            % Read the calibration file line-by-line, skipping comment lines (%).
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
            % Interpolate the calibration curve to get photon flux at a
            % given voltage, then apply NDF attenuation.
            %
            % flux = getFluxAtVoltage(obj, voltage, ndf)
            %   voltage - LED driver voltage (0-10 V)
            %   ndf     - ND filter value (0, 0.5, 1.0, 2.0, 3.0, 4.0)
            %
            % Returns photons/cm2/s

            if voltage <= 0
                flux = 0;
                return;
            end

            % Clamp voltage to calibration range.
            voltage = min(voltage, max(obj.calibrationVoltage));

            % Interpolate flux at NDF 0.
            fluxNdf0 = interp1(obj.calibrationVoltage, obj.calibrationFlux, voltage, 'pchip');

            % Apply NDF attenuation: 10^(-NDF).
            flux = fluxNdf0 / (10^ndf);
        end

        function updateFluxDisplay(obj, ndf)
            % Update the flux display text fields.
            if nargin < 2 || isempty(ndf)
                ndf = get(obj.ndfSettingPopupMenu, 'Value');
            end
            if iscell(ndf)
                ndf = ndf{1};
            end
            if isempty(ndf) || ~isnumeric(ndf)
                ndf = 0;
            end

            if isempty(obj.calibrationFlux)
                return;
            end

            % Max flux = flux at 10V.
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

    end

    methods (Static)
        function str = formatScientific(num)
            % Format a number in scientific notation like "7.23e+16".
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
