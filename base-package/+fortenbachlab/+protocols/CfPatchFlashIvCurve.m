classdef CfPatchFlashIvCurve < fortenbachlab.protocols.FortenbachLabProtocol
    % IV curve with a timed light flash delivered during each voltage step.
    %
    % Steps the amplifier across a range of holding potentials (identical to
    % CfPatchIvCurve) and delivers a brief LED flash at a fixed delay into
    % each voltage step.  Two analysis figures plot the light-evoked peak
    % current and integrated charge as functions of holding potential,
    % building up IV-style curves that reveal the reversal potential and
    % conductance of the light-evoked response.
    %
    % Timing (defaults):
    %   preTime 50 ms | ---------- stimTime 500 ms ---------- | tailTime 50 ms
    %                     200 ms      |10 ms|
    %                   (flashDelay)  (flash)
    %
    % The LED is always active: lightBackground sets the background and
    % flashAmplitude sets the flash intensity above background.

    properties
        amp                             % Output amplifier
        led                             % Output LED
        preTime = 100                   % Pulse leading duration (ms)
        stimTime = 500                  % Voltage step duration (ms)
        tailTime = 50                   % Pulse trailing duration (ms)
        flashDelay = 200                % Delay from step onset to flash onset (ms)
        flashTime = 10                  % Flash duration (ms)
        firstPulseSignal = -80          % First pulse signal value (mV or pA depending on amp mode)
        incrementPerPulse = 10          % Increment value per each pulse (mV or pA depending on amp mode)
        pulsesInFamily = uint16(11)     % Number of pulses in family
        numberOfAverages = uint16(5)    % Number of families
        interpulseInterval = 0          % Duration between pulses (s)
        flashAmplitude = 5              % Flash amplitude: LED voltage above background (V)
        lightBackground = 0                   % Background amplitude: LED DC voltage (V [0-10])
        ndf = 0.0                       % ND filter setting
        chargeIntegrationTime = 200     % Window after flash onset for charge integration (ms)
        amp2PulseSignal = -60           % Pulse signal value for secondary amp (mV or pA depending on amp2 mode)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Dependent)
        backgroundIntensity            % Background intensity (photons/cm2/s). Accepts scientific notation, e.g. '1.5e15'.
    end

    properties (Hidden)
        ampType
        ledType
        ndfType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
        peakIvFigure
        chargeIvFigure
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

            % Constrain NDF to valid filter wheel values.
            if strcmp(name, 'ndf')
                d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', ...
                    {0, 0.5, 1.0, 2.0, 3.0, 4.0});
            end

            % Treat backgroundIntensity as an editable string so scientific
            % notation input (e.g. "1.5e15") is accepted and displayed.
            if strcmp(name, 'backgroundIntensity')
                d.type = symphonyui.core.PropertyType('char', 'row');
            end

            % Categories and display names.
            switch name
                case 'preTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Pre Time (ms)';
                case 'stimTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Stim Time (ms)';
                case 'tailTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Tail Time (ms)';
                case 'flashTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Flash Time (ms)';
                case 'flashDelay'
                    d.category = 'Stimulus';
                    d.displayName = 'Flash Delay (ms)';
                case 'firstPulseSignal'
                    d.category = 'Stimulus';
                    d.displayName = 'First Pulse Signal (mV)';
                case 'incrementPerPulse'
                    d.category = 'Stimulus';
                    d.displayName = 'Increment Per Pulse (mV)';
                case 'pulsesInFamily'
                    d.category = 'Stimulus';
                    d.displayName = 'Pulses In Family';
                case 'chargeIntegrationTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Charge Integration Time (ms)';
                case 'flashAmplitude'
                    d.category = 'Light';
                    d.displayName = 'Flash Amplitude (V)';
                case 'lightBackground'
                    d.category = 'Light';
                    d.displayName = 'Background Voltage (V)';
                case {'led', 'ndf', 'flashIntensity', 'backgroundIntensity'}
                    d.category = 'Light';
                case {'amp', 'amp2'}
                    d.category = 'Amplifier';
                case 'numberOfAverages'
                    d.category = 'Acquisition';
                    d.displayName = 'Number of Averages';
                case 'interpulseInterval'
                    d.category = 'Acquisition';
                    d.displayName = 'Interpulse Interval (s)';
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

            % --- Standard response figures ---
            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
                obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp), ...
                    'groupBy', {'pulseSignal'});
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', ...
                    obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', ...
                    obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2), ...
                    'groupBy1', {'pulseSignal'}, ...
                    'groupBy2', {'pulseSignal'});
                obj.showFigure('fortenbachlab.figures.DualResponseStatisticsFigure', ...
                    obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    obj.rig.getDevice(obj.amp2), {@mean, @var}, ...
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

            % --- Peak flash response IV figure ---
            obj.peakIvFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.updatePeakIvFigure);
            f1 = obj.peakIvFigure.getFigureHandle();
            set(f1, 'Name', 'Flash Peak IV');
            delete(findall(f1, 'Type', 'axes'));  % Remove axes from prior run
            obj.peakIvFigure.userData.ax = axes('Parent', f1);
            xlabel(obj.peakIvFigure.userData.ax, 'Holding Potential (mV)');
            ylabel(obj.peakIvFigure.userData.ax, 'Peak Current');
            title(obj.peakIvFigure.userData.ax, 'Flash Peak IV');
            hold(obj.peakIvFigure.userData.ax, 'on');
            grid(obj.peakIvFigure.userData.ax, 'on');
            obj.peakIvFigure.userData.ivData = containers.Map('KeyType', 'double', 'ValueType', 'any');

            % --- Flash charge IV figure ---
            obj.chargeIvFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.updateChargeIvFigure);
            f2 = obj.chargeIvFigure.getFigureHandle();
            set(f2, 'Name', 'Flash Charge IV');
            delete(findall(f2, 'Type', 'axes'));  % Remove axes from prior run
            obj.chargeIvFigure.userData.ax = axes('Parent', f2);
            xlabel(obj.chargeIvFigure.userData.ax, 'Holding Potential (mV)');
            ylabel(obj.chargeIvFigure.userData.ax, 'Charge');
            title(obj.chargeIvFigure.userData.ax, 'Flash Charge IV');
            hold(obj.chargeIvFigure.userData.ax, 'on');
            grid(obj.chargeIvFigure.userData.ax, 'on');
            obj.chargeIvFigure.userData.ivData = containers.Map('KeyType', 'double', 'ValueType', 'any');

            % --- Set up filter wheel and LED background ---
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
                warning('CfPatchFlashIvCurve:setNDFFailed', ...
                    'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
            end
            obj.setLedBackground(obj.led, obj.lightBackground);
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
            % LED waveform: constant at lightBackground for the full epoch, with a
            % flash of flashAmplitude above background starting at
            % (preTime + flashDelay) and lasting flashTime.
            device = obj.rig.getDevice(obj.led);
            units = device.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            prePts        = timeToPts(obj.preTime);
            stimPts       = timeToPts(obj.stimTime);
            tailPts       = timeToPts(obj.tailTime);
            flashDelayPts = timeToPts(obj.flashDelay);
            flashPts      = timeToPts(obj.flashTime);

            totalPts = prePts + stimPts + tailPts;
            data = ones(1, totalPts) * obj.lightBackground;

            % Flash onset is flashDelay into the voltage step.
            flashOnset = prePts + flashDelayPts + 1;
            flashOffset = min(flashOnset + flashPts - 1, totalPts);
            data(flashOnset:flashOffset) = obj.lightBackground + obj.flashAmplitude;

            stim = obj.createStimulusFromArray(data, units);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            pulseNum = mod(obj.numEpochsPrepared - 1, obj.pulsesInFamily) + 1;
            [stim, pulseSignal] = obj.createAmpStimulus(pulseNum);

            epoch.addParameter('pulseSignal', pulseSignal);
            epoch.addStimulus(obj.rig.getDevice(obj.amp), stim);
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            % LED flash stimulus.
            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
            epoch.addParameter('flashAmplitude', obj.flashAmplitude);
            epoch.addParameter('lightBackground', obj.lightBackground);
            epoch.addParameter('ndf', obj.ndf);
            epoch.addParameter('flashDelay', obj.flashDelay);
            epoch.addParameter('flashTime', obj.flashTime);
            epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightBackground, obj.ndf));

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addStimulus(obj.rig.getDevice(obj.amp2), obj.createAmp2Stimulus());
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function completeEpoch(obj, epoch)
            % Compute flash-evoked analysis metrics and store as epoch
            % parameters so they are saved with the data.
            try
                device = obj.rig.getDevice(obj.amp);
                response = epoch.getResponse(device);
                if ~isempty(response)
                    [quantities, ~] = response.getData();
                    try
                        [fullQ, ~] = response.getFullData();
                        if ~isempty(fullQ), quantities = fullQ; end
                    catch
                    end

                    [peakResp, charge] = obj.computeFlashMetrics(quantities);
                    epoch.addParameter('flashPeakResponse', peakResp);
                    epoch.addParameter('flashCharge', charge);
                end
            catch
            end

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

            % Hold LED at lightBackground during inter-pulse interval.
            ledDevice = obj.rig.getDevice(obj.led);
            interval.addDirectCurrentStimulus(ledDevice, ledDevice.background, obj.interpulseInterval, obj.sampleRate);
        end

        function completeRun(obj)
            completeRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Turn off LED when the run ends.
            try
                ledDevice = obj.rig.getDevice(obj.led);
                units = ledDevice.background.displayUnits;
                ledDevice.background = symphonyui.core.Measurement(0, units);
                ledDevice.applyBackground();
            catch e
                warning('CfPatchFlashIvCurve:LedOffFailed', ...
                    'Failed to turn off LED: %s', e.message);
            end
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages * obj.pulsesInFamily;
        end

        % ================================================================
        %  ANALYSIS FIGURE CALLBACKS
        % ================================================================

        function updatePeakIvFigure(obj, figureHandler, epoch)
            % Accumulates peak flash-evoked current for each voltage step
            % and plots mean +/- SE.
            try
                pulseSignal = epoch.parameters('pulseSignal');

                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, ~] = responseData.getData();
                try
                    [fullQ, ~] = responseData.getFullData();
                    if ~isempty(fullQ), quantities = fullQ; end
                catch
                end

                [peakResp, ~] = obj.computeFlashMetrics(quantities);

                ivData = figureHandler.userData.ivData;
                if ivData.isKey(pulseSignal)
                    ivData(pulseSignal) = [ivData(pulseSignal), peakResp];
                else
                    ivData(pulseSignal) = peakResp;
                end

                obj.plotIvCurve(figureHandler.userData.ax, ivData, ...
                    'Holding Potential (mV)', 'Peak Current', 'A', 'Flash Peak IV');
            catch
            end
        end

        function updateChargeIvFigure(obj, figureHandler, epoch)
            % Accumulates integrated charge of flash-evoked current for
            % each voltage step and plots mean +/- SE.
            try
                pulseSignal = epoch.parameters('pulseSignal');

                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, ~] = responseData.getData();
                try
                    [fullQ, ~] = responseData.getFullData();
                    if ~isempty(fullQ), quantities = fullQ; end
                catch
                end

                [~, charge] = obj.computeFlashMetrics(quantities);

                ivData = figureHandler.userData.ivData;
                if ivData.isKey(pulseSignal)
                    ivData(pulseSignal) = [ivData(pulseSignal), charge];
                else
                    ivData(pulseSignal) = charge;
                end

                obj.plotIvCurve(figureHandler.userData.ax, ivData, ...
                    'Holding Potential (mV)', 'Charge', 'C', 'Flash Charge IV');
            catch
            end
        end

        % ================================================================
        %  DEPENDENT PROPERTY ACCESSORS
        % ================================================================

        function a = get.amp2(obj)
            amps = obj.rig.getDeviceNames('Amp');
            if numel(amps) < 2
                a = '(None)';
            else
                i = find(~ismember(amps, obj.amp), 1);
                a = amps{i};
            end
        end

        function s = get.backgroundIntensity(obj)
            if obj.lightBackground == 0
                s = '0';
                return;
            end
            try
                f = obj.getPhotonFlux(obj.lightBackground, obj.ndf);
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

        function set.backgroundIntensity(obj, val)
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
                warning('CfPatchFlashIvCurve:NoCalibration', ...
                    'LED calibration not loaded; cannot set backgroundIntensity.');
                return;
            end
            vMean = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf, obj.objective);
            if isnan(vMean), vMean = 10; end
            if vMean < 0, vMean = 0; end
            obj.lightBackground = vMean;
        end

    end

    % ====================================================================
    %  PRIVATE HELPERS
    % ====================================================================
    methods (Access = private)

        function [peakResp, charge] = computeFlashMetrics(obj, quantities)
            %COMPUTEFLASHMETRICS  Peak current and integrated charge from flash.
            %   Computes a pre-flash baseline (up to 50 ms before flash
            %   onset, within the voltage step), then finds the signed peak
            %   deviation and time-integrated charge in the analysis window
            %   after flash onset.  Values are in base-SI units (Amps for
            %   peak, Coulombs for charge).
            sr = obj.sampleRate;
            prePts        = round(obj.preTime  / 1e3 * sr);
            flashDelayPts = round(obj.flashDelay / 1e3 * sr);
            integrationPts = round(obj.chargeIntegrationTime / 1e3 * sr);

            % Pre-flash baseline: up to 50 ms before flash, within the step.
            baselineMs  = min(50, obj.flashDelay);
            baselinePts = round(baselineMs / 1e3 * sr);
            blEnd   = prePts + flashDelayPts;
            blStart = blEnd - baselinePts + 1;
            baseline = mean(quantities(max(1, blStart):blEnd));

            % Analysis window: flash onset to onset + chargeIntegrationTime.
            flashOnsetPt = prePts + flashDelayPts + 1;
            analysisEnd  = min(flashOnsetPt + integrationPts - 1, numel(quantities));

            if flashOnsetPt > numel(quantities)
                peakResp = 0;
                charge   = 0;
                return;
            end

            deviation = quantities(flashOnsetPt:analysisEnd) - baseline;

            % Peak: signed value at time of maximum absolute deviation.
            [~, maxIdx] = max(abs(deviation));
            peakResp = deviation(maxIdx);   % Amps (base SI)

            % Charge: time-integral of deviation (A * s = Coulombs).
            charge = sum(deviation) / sr;
        end

        function plotIvCurve(obj, ax, ivData, xLabel, yBaseLabel, baseUnit, titleStr)
            %PLOTIVCURVE  Rebuild mean +/- SE errorbar plot from accumulated data.
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

            % Auto-scale for display (e.g. Amps -> pA, Coulombs -> pC).
            [scaledMeans, yUnits] = obj.siAutoScale(means, baseUnit);
            if isempty(yUnits), yUnits = baseUnit; end

            % Scale SEs by the same factor used for means.
            if any(means ~= 0)
                idx = find(means ~= 0, 1);
                scaleFactor = scaledMeans(idx) / means(idx);
            else
                scaleFactor = 1;
            end
            scaledSes = ses * scaleFactor;

            errorbar(ax, voltages, scaledMeans, scaledSes, 'o-', ...
                'Color', [0 0.4470 0.7410], ...
                'MarkerFaceColor', [0 0.4470 0.7410], ...
                'MarkerSize', 6, ...
                'LineWidth', 1.5, ...
                'CapSize', 8);
            xlabel(ax, xLabel);
            ylabel(ax, [yBaseLabel ' (' yUnits ')']);
            title(ax, titleStr);
            grid(ax, 'on');

            % Zero-crossing reference line.
            xlims = get(ax, 'XLim');
            line(ax, xlims, [0 0], 'Color', [0.5 0.5 0.5], ...
                'LineStyle', '--', 'HandleVisibility', 'off');
        end

    end

    methods (Static, Access = private)

        function [scaledData, scaledUnits] = siAutoScale(data, units)
            %SIAUTOSCALE  Pick an SI prefix so axis tick labels stay readable.
            %   getData() returns numeric values in BASE SI units (e.g. Amps)
            %   but may label them with a prefixed string (e.g. 'pA').
            %   We strip any existing prefix so we always work from the
            %   base unit, then choose the right prefix for the magnitude.
            scaledData  = data;
            scaledUnits = units;
            if isempty(data), return; end
            peak = max(abs(data(:)));
            if peak == 0 || ~isfinite(peak), return; end
            if isempty(units), units = ''; end

            % Strip existing SI prefix to recover the base unit.
            siPrefixes = {'p', 'n', char(181), 'u', 'm', 'k', 'M', 'G', 'T'};
            baseUnit = units;
            if numel(units) >= 2 && any(strcmp(units(1), siPrefixes))
                baseUnit = units(2:end);
            end

            % If values are already in a comfortable range, keep as-is
            % but label with the base unit (no misleading prefix).
            if peak >= 0.1 && peak < 1e4
                scaledData  = data;
                scaledUnits = baseUnit;
                return;
            end

            ex = floor(log10(peak));
            if ex <= -10
                scaledData = data * 1e12; scaledUnits = ['p' baseUnit];
            elseif ex <= -7
                scaledData = data * 1e9;  scaledUnits = ['n' baseUnit];
            elseif ex <= -4
                scaledData = data * 1e6;  scaledUnits = [char(181) baseUnit];
            elseif ex <= -1
                scaledData = data * 1e3;  scaledUnits = ['m' baseUnit];
            end
        end

    end

end
