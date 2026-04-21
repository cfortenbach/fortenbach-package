classdef CfPatchIvCurve < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents families of rectangular pulse stimuli to a specified amplifier and records responses from the same
    % amplifier to generate an IV curve. Each family consists of a set of pulse stimuli with signal value starting at
    % firstPulseSignal. With each subsequent pulse in the family, the signal value is incremented by incrementPerPulse.
    % The family is complete when this sequence has been executed pulsesInFamily times.
    %
    % Optionally, a continuous background light can be presented on an LED
    % for the entire duration of the run.  When lightOn is false (default),
    % no LED stimulus is delivered. When lightOn is true, the LED is held
    % at lightMean for every epoch (including inter-pulse intervals) and
    % the filter wheel is set to the selected NDF.
    %
    % For example, with values firstPulseSignal = 100, incrementPerPulse = 10, and pulsesInFamily = 5, the sequence of
    % pulse stimuli signal values would be: 100 then 110 then 120 then 130 then 140.

    properties
        amp                             % Output amplifier
        preTime = 50                    % Pulse leading duration (ms)
        stimTime = 500                  % Pulse duration (ms)
        tailTime = 50                   % Pulse trailing duration (ms)
        firstPulseSignal = -80          % First pulse signal value (mV or pA depending on amp mode)
        incrementPerPulse = 10          % Increment value per each pulse (mV or pA depending on amp mode)
        pulsesInFamily = uint16(11)     % Number of pulses in family
        lightOn = false                 % Turn on continuous background light during run
        led                             % Output LED (used when lightOn is true)
        lightMean = 0                   % LED background voltage (V [0-10])
        ndf = 0.0                       % ND filter setting (applied to filter wheel when lightOn is true)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Dependent)
        photonFluxBackground            % Estimated photon flux at lightMean (photons/cm2/s). Accepts scientific notation, e.g. '1.5e15'.
    end

    properties
        amp2PulseSignal = -60           % Pulse signal value for secondary amp (mV or pA depending on amp2 mode)
        numberOfAverages = uint16(5)    % Number of families
        interpulseInterval = 0          % Duration between pulses (s)
    end

    properties (Hidden)
        ampType
        ledType
        ndfType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
        ivFigure
    end

    methods

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
            [obj.led, obj.ledType] = obj.createDeviceNamesProperty('LED');
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.FortenbachLabProtocol(obj, name);

            if strncmp(name, 'amp2', 4) && numel(obj.rig.getDeviceNames('Amp')) < 2
                d.isHidden = true;
            end

            % Hide light-related fields when lightOn is false.
            if ~obj.lightOn && (strcmp(name, 'led') || strcmp(name, 'lightMean') ...
                    || strcmp(name, 'ndf') || strcmp(name, 'photonFluxBackground'))
                d.isHidden = true;
            end

            % Constrain NDF to valid filter wheel values.
            if strcmp(name, 'ndf')
                d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', ...
                    {0, 0.5, 1.0, 2.0, 3.0, 4.0});
            end

            % Treat photonFluxBackground as an editable string so scientific
            % notation input (e.g. "1.5e15") is accepted and displayed.
            if strcmp(name, 'photonFluxBackground')
                d.type = symphonyui.core.PropertyType('char', 'row');
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()createPreviewStimuli(obj));
            function s = createPreviewStimuli(obj)
                s = cell(1, obj.pulsesInFamily);
                for i = 1:numel(s)
                    s{i} = obj.createAmpStimulus(i);
                end
            end
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
                obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp), ...
                    'groupBy', {'pulseSignal'});
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2), ...
                    'groupBy1', {'pulseSignal'}, ...
                    'groupBy2', {'pulseSignal'});
                obj.showFigure('fortenbachlab.figures.DualResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, obj.rig.getDevice(obj.amp2), {@mean, @var}, ...
                    'baselineRegion1', [0 obj.preTime], ...
                    'measurementRegion1', [obj.preTime obj.preTime+obj.stimTime], ...
                    'baselineRegion2', [0 obj.preTime], ...
                    'measurementRegion2', [obj.preTime obj.preTime+obj.stimTime]);
            end

            if obj.cellHealthEnabled()
                obj.showFigure('fortenbachlab.figures.CellHealthFigure', obj.rig.getDevice(obj.amp));
            else
                obj.warnCellHealthDisabled();
            end

            % IV curve figure (mean +/- SE, updated after each epoch).
            obj.ivFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.updateIvFigure);
            f = obj.ivFigure.getFigureHandle();
            set(f, 'Name', 'IV Curve');
            obj.ivFigure.userData.ax = axes('Parent', f);
            xlabel(obj.ivFigure.userData.ax, 'Membrane Potential (mV)');
            ylabel(obj.ivFigure.userData.ax, 'Current (pA)');
            title(obj.ivFigure.userData.ax, 'IV Curve');
            hold(obj.ivFigure.userData.ax, 'on');
            grid(obj.ivFigure.userData.ax, 'on');
            % Storage: map from pulseSignal -> array of steady-state currents.
            obj.ivFigure.userData.ivData = containers.Map('KeyType', 'double', 'ValueType', 'any');

            % If light is enabled, set the filter wheel and turn on the LED.
            if obj.lightOn
                % Move filter wheel to selected NDF with settle time.
                try
                    fws = obj.rig.getDevices('FilterWheel');
                    if ~isempty(fws)
                        currentNDF = fws{1}.getConfigurationSetting('NDF');
                        fws{1}.setNDF(obj.ndf);
                        if ~isequal(currentNDF, obj.ndf)
                            pause(4);
                        end
                    end
                catch e
                    warning('CfPatchIvCurve:setNDFFailed', ...
                        'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
                end

                % Ramp up the LED background.
                obj.setLedBackground(obj.led, obj.lightMean);
            end
        end

        function [stim, pulseSignal] = createAmpStimulus(obj, pulseNum)
            pulseSignal = obj.incrementPerPulse * (double(pulseNum) - 1) + obj.firstPulseSignal;

            device = obj.rig.getDevice(obj.amp);
            bg = device.background.quantity;
            units = device.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            prePts  = timeToPts(obj.preTime);
            stimPts = timeToPts(obj.stimTime);
            tailPts = timeToPts(obj.tailTime);

            data = ones(1, prePts + stimPts + tailPts) * bg;
            data(prePts+1 : prePts+stimPts) = pulseSignal;

            % Embed cell-health test pulse in pre-time (if enabled).
            if obj.cellHealthEnabled()
                data = obj.embedTestPulse(data, obj.amp);
            end

            stim = obj.createStimulusFromArray(data, units);
        end

        function stim = createAmp2Stimulus(obj)
            gen = symphonyui.builtin.stimuli.PulseGenerator();

            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.mean = obj.rig.getDevice(obj.amp2).background.quantity;
            gen.amplitude = obj.amp2PulseSignal - gen.mean;
            gen.sampleRate = obj.sampleRate;
            gen.units = obj.rig.getDevice(obj.amp2).background.displayUnits;

            stim = gen.generate();
        end

        function stim = createLedStimulus(obj)
            % Continuous DC stimulus at lightMean for the full epoch.
            gen = symphonyui.builtin.stimuli.PulseGenerator();

            gen.preTime = 0;
            gen.stimTime = obj.preTime + obj.stimTime + obj.tailTime;
            gen.tailTime = 0;
            gen.amplitude = 0;
            gen.mean = obj.lightMean;
            gen.sampleRate = obj.sampleRate;
            gen.units = obj.rig.getDevice(obj.led).background.displayUnits;

            stim = gen.generate();
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            pulseNum = mod(obj.numEpochsPrepared - 1, obj.pulsesInFamily) + 1;
            [stim, pulseSignal] = obj.createAmpStimulus(pulseNum);

            epoch.addParameter('pulseSignal', pulseSignal);
            epoch.addStimulus(obj.rig.getDevice(obj.amp), stim);
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            % Add continuous light stimulus if enabled.
            if obj.lightOn
                epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
                epoch.addParameter('lightOn', true);
                epoch.addParameter('lightMean', obj.lightMean);
                epoch.addParameter('ndf', obj.ndf);
                epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, obj.ndf));
            else
                epoch.addParameter('lightOn', false);
            end

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addStimulus(obj.rig.getDevice(obj.amp2), obj.createAmp2Stimulus());
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function completeEpoch(obj, epoch)
            completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            if obj.cellHealthEnabled()
                try
                    testAmp = obj.testPulseAmplitude(obj.amp);
                    metrics = obj.computeCellHealthMetrics(epoch, obj.amp, testAmp, 5, 20);
                    obj.saveCellHealthMetrics(epoch, metrics);
                catch
                end
            end
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);

            device = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(device, device.background, obj.interpulseInterval, obj.sampleRate);

            % Hold LED at lightMean during inter-pulse interval.
            if obj.lightOn
                ledDevice = obj.rig.getDevice(obj.led);
                interval.addDirectCurrentStimulus(ledDevice, ledDevice.background, obj.interpulseInterval, obj.sampleRate);
            end
        end

        function completeRun(obj)
            completeRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Turn off the LED when the run ends.
            if obj.lightOn
                try
                    ledDevice = obj.rig.getDevice(obj.led);
                    units = ledDevice.background.displayUnits;
                    % Set background to 0 so Symphony knows the new idle level.
                    ledDevice.background = symphonyui.core.Measurement(0, units);
                    % Apply immediately by writing the background to the
                    % device output stream so the DAC actually goes to 0.
                    ledDevice.applyBackground();
                catch e
                    warning('CfPatchIvCurve:LedOffFailed', ...
                        'Failed to turn off LED: %s', e.message);
                end
            end
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function updateIvFigure(obj, figureHandler, epoch)
            % Called after each epoch. Accumulates steady-state current
            % measurements for each voltage step and plots mean +/- SE.
            try
                pulseSignal = epoch.parameters('pulseSignal');
                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, ~] = responseData.getData();

                sr = obj.sampleRate;
                prePts  = round(obj.preTime  / 1e3 * sr);
                stimPts = round(obj.stimTime / 1e3 * sr);

                % Baseline-subtracted steady-state current (second half of
                % stimulus window).
                baseline    = mean(quantities(1:prePts));
                ssStart     = prePts + round(stimPts * 0.5);
                ssEnd       = prePts + stimPts;
                steadyState = mean(quantities(ssStart:ssEnd)) - baseline;

                % Accumulate into the map.
                ivData = figureHandler.userData.ivData;
                if ivData.isKey(pulseSignal)
                    ivData(pulseSignal) = [ivData(pulseSignal), steadyState];
                else
                    ivData(pulseSignal) = steadyState;
                end

                % Rebuild the IV plot.
                ax = figureHandler.userData.ax;
                cla(ax);
                voltages = cell2mat(ivData.keys);
                voltages = sort(voltages);
                means = zeros(size(voltages));
                ses   = zeros(size(voltages));
                for i = 1:numel(voltages)
                    vals = ivData(voltages(i));
                    means(i) = mean(vals);
                    if numel(vals) > 1
                        ses(i) = std(vals) / sqrt(numel(vals));
                    end
                end

                errorbar(ax, voltages, means, ses, 'o-', ...
                    'Color', [0 0.4470 0.7410], ...
                    'MarkerFaceColor', [0 0.4470 0.7410], ...
                    'MarkerSize', 6, ...
                    'LineWidth', 1.5, ...
                    'CapSize', 8);
                xlabel(ax, 'Membrane Potential (mV)');
                ylabel(ax, 'Current (pA)');
                title(ax, 'IV Curve');
                grid(ax, 'on');

                % Draw a light reference line at y=0.
                xlims = get(ax, 'XLim');
                line(ax, xlims, [0 0], 'Color', [0.5 0.5 0.5], 'LineStyle', '--', 'HandleVisibility', 'off');
            catch
                % Silently skip if data isn't available yet.
            end
        end

        function a = get.amp2(obj)
            amps = obj.rig.getDeviceNames('Amp');
            if numel(amps) < 2
                a = '(None)';
            else
                i = find(~ismember(amps, obj.amp), 1);
                a = amps{i};
            end
        end

        function s = get.photonFluxBackground(obj)
            if ~obj.lightOn
                s = 'light off';
                return;
            end
            try
                f = obj.getPhotonFlux(obj.lightMean, obj.ndf);
                if isempty(f) || ~isfinite(f) || f == 0
                    s = '0';
                else
                    exponent = floor(log10(abs(f)));
                    mantissa = f / 10^exponent;
                    s = sprintf('%.2fe%+03d', mantissa, exponent);
                end
            catch
                s = 'N/A';
            end
        end

        function set.photonFluxBackground(obj, val)
            if isnumeric(val)
                targetFlux = double(val);
            elseif ischar(val) || isstring(val)
                str = strtrim(char(val));
                tok = regexp(str, '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?', 'match', 'once');
                if isempty(tok), return; end
                targetFlux = str2double(tok);
            else
                return;
            end
            if isempty(targetFlux) || ~isfinite(targetFlux) || targetFlux < 0, return; end
            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration)
                warning('CfPatchIvCurve:NoCalibration', ...
                    'LED calibration not loaded; cannot set photonFluxBackground.');
                return;
            end
            vMean = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf);
            if isnan(vMean), vMean = 10; end
            if vMean < 0, vMean = 0; end
            obj.lightMean = vMean;
        end

    end

end
