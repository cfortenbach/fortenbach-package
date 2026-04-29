classdef CfPatchFlashFamily < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents families of escalating-intensity flash stimuli to an LED and
    % records from an amplifier in voltage-clamp or current-clamp mode.
    %
    % Each family consists of pulsesInFamily flashes. The LED voltage doubles
    % with each successive pulse. When autoNDF is enabled, the filter wheel
    % automatically advances to the next lower NDF (more light) when the
    % voltage would exceed 10 V, and the voltage is recomputed via the
    % calibration curve to deliver 2x the flux of the previous pulse.
    %
    % The amplifier AO delivers a flat holding potential (at the amp
    % background) with an optional cell health test pulse embedded in
    % pre-time — it does NOT send an MCS-encoded stimulus.
    %
    % Workflow:
    %   1. Go whole-cell in voltage clamp.
    %   2. Set holding potential in MultiClamp Commander.
    %   3. Run this protocol — it delivers escalating flashes with
    %      automatic NDF switching and monitors cell health.
    %
    % Features:
    %   - Voltage-doubling flash family with automatic NDF switching
    %   - Cell health monitoring (Rinput, Ihold) via test pulse in pre-time
    %   - Flash onset figure (zoomed view around flash onset)
    %   - Photon flux display and entry in scientific notation
    %   - Hardware-timed filter wheel settle delay (2 s via prepareInterval)
    %   - Dual amplifier support

    properties
        led                             % Output LED
        preTime = 50                    % Pulse leading duration (ms)
        stimTime = 10                   % Pulse duration (ms)
        tailTime = 3000                 % Pulse trailing duration (ms)
        firstLightAmplitude = 1         % First pulse amplitude (V [0-10])
        pulsesInFamily = uint16(3)      % Number of pulses in family
        lightMean = 0                   % Pulse and LED background mean (V)
        ndf = 0.0                       % ND filter setting (when autoNDF is off)
        autoNDF = false                 % Automatically switch NDF when voltage exceeds 10 V
        startingNDF = 4.0               % Starting NDF value (used when autoNDF is true)
        numberOfAverages = uint16(5)    % Number of family repeats
        interpulseInterval = 0          % Duration between pulses (s)
        amp                             % Input amplifier
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
        photonFluxPeakMax               % Photon flux at last (brightest) pulse
        photonFluxBackground            % Estimated photon flux at lightMean
    end

    properties (Dependent)
        photonFluxPeakMin               % Photon flux at first (dimmest) pulse. Accepts scientific notation.
    end

    properties
        showOnsetFigure = true          % Show zoomed flash onset figure
        onsetPrePad = 5                 % Flash onset window: ms before onset
        onsetPostPad = 100              % Flash onset window: ms after onset
    end

    properties (Hidden)
        ledType
        ampType
        ndfType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
        startingNDFType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
        lastNdf = NaN           % Tracks the NDF used by the previous epoch
        intervalCount = 0       % Number of inter-epoch intervals completed
    end

    properties (Constant, Hidden)
        NDF_VALUES = [0 0.5 1.0 2.0 3.0 4.0];  % Available NDF positions (ascending)
    end

    methods

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            [obj.led, obj.ledType] = obj.createDeviceNamesProperty('LED');
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.FortenbachLabProtocol(obj, name);

            if strncmp(name, 'amp2', 4) && numel(obj.rig.getDeviceNames('Amp')) < 2
                d.isHidden = true;
            end

            % Hide startingNDF when autoNDF is off; hide ndf when autoNDF is on.
            if strcmp(name, 'startingNDF') && ~obj.autoNDF
                d.isHidden = true;
            end
            if strcmp(name, 'ndf') && obj.autoNDF
                d.isHidden = true;
            end

            % Constrain NDF to valid filter wheel values.
            if strcmp(name, 'ndf')
                d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', ...
                    {0, 0.5, 1.0, 2.0, 3.0, 4.0});
            end

            % Treat photon flux fields as editable strings so scientific
            % notation input (e.g. "1.5e15") is accepted and displayed.
            if strcmp(name, 'photonFluxPeakMin')
                d.type = symphonyui.core.PropertyType('char', 'row');
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()createPreviewStimuli(obj));
            function s = createPreviewStimuli(obj)
                s = cell(1, obj.pulsesInFamily);
                for i = 1:numel(s)
                    s{i} = obj.createLedStimulus(i);
                end
            end
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            obj.intervalCount = 0;

            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('fortenbachlab.figures.ResponseStimulusFigure', ...
                    obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.led));
                obj.showFigure('fortenbachlab.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp), ...
                    'groupBy', {'lightAmplitude'}, ...
                    'ledDevice', obj.rig.getDevice(obj.led));
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2), ...
                    'groupBy1', {'lightAmplitude'}, ...
                    'groupBy2', {'lightAmplitude'});
                obj.showFigure('fortenbachlab.figures.DualResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, obj.rig.getDevice(obj.amp2), {@mean, @var}, ...
                    'baselineRegion1', [0 obj.preTime], ...
                    'measurementRegion1', [obj.preTime obj.preTime+obj.stimTime], ...
                    'baselineRegion2', [0 obj.preTime], ...
                    'measurementRegion2', [obj.preTime obj.preTime+obj.stimTime]);
            end

            % Set filter wheel to starting NDF.
            if obj.autoNDF
                try
                    fws = obj.rig.getDevices('FilterWheel');
                    if ~isempty(fws)
                        currentNDF = fws{1}.getConfigurationSetting('NDF');
                        obj.setFilterWheelNDF(obj.startingNDF);
                        if ~isequal(currentNDF, obj.startingNDF)
                            pause(4);
                        end
                    end
                catch
                    obj.setFilterWheelNDF(obj.startingNDF);
                    pause(4);
                end
                obj.lastNdf = obj.startingNDF;
            else
                % Set filter wheel to selected NDF with settle time.
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
                    warning('CfPatchFlashFamily:setNDFFailed', ...
                        'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
                end
                obj.lastNdf = obj.getCurrentNDF();
            end

            obj.setLedBackground(obj.led, obj.lightMean);

            if obj.cellHealthEnabled()
                obj.showFigure('fortenbachlab.figures.CellHealthFigure', obj.rig.getDevice(obj.amp));
            else
                obj.warnCellHealthDisabled();
            end

            if obj.showOnsetFigure
                obj.showFigure('fortenbachlab.figures.FlashOnsetFigure', obj.rig.getDevice(obj.amp), ...
                    'preTime', obj.preTime, ...
                    'prePad', obj.onsetPrePad, ...
                    'postPad', obj.onsetPostPad, ...
                    'ledDevice', obj.rig.getDevice(obj.led), ...
                    'groupBy', 'lightAmplitude');
            end

            obj.showFigure('fortenbachlab.figures.IntensityResponseFigure', obj.rig.getDevice(obj.amp), ...
                'preTime', obj.preTime, ...
                'stimTime', obj.stimTime);

            [pfVoltages, pfNdfs, pfFluxes] = obj.computePulseTable();
            obj.showFigure('fortenbachlab.figures.ProgressFigure', obj.numberOfAverages * obj.pulsesInFamily, ...
                'flashVoltages', pfVoltages, ...
                'flashNdfs', pfNdfs, ...
                'flashFluxes', pfFluxes, ...
                'pulsesInFamily', obj.pulsesInFamily);
        end

        % ------------------------------------------------------------------
        %  Compute the (voltage, NDF) pair for each pulse in the family.
        % ------------------------------------------------------------------

        function [voltages, ndfs, fluxes] = computePulseTable(obj)
            % COMPUTEPULSETABLE  Pre-compute voltage, NDF, and photon flux
            % for every pulse in the family.
            %
            % When autoNDF is false: voltage doubles each step at the
            % current NDF setting.
            %
            % When autoNDF is true:
            %   1. The first pulse is firstLightAmplitude at startingNDF.
            %   2. The LED voltage doubles each step.
            %   3. When the doubled voltage would exceed 10 V, the filter
            %      wheel steps to the next lower NDF (more light) and the
            %      voltage is recomputed from the calibration curve to
            %      deliver 2x the flux of the previous pulse.
            %   4. Voltage doubling then continues at the new NDF.

            n = double(obj.pulsesInFamily);
            voltages = zeros(1, n);
            ndfs     = zeros(1, n);
            fluxes   = zeros(1, n);

            obj.ensureCalibrationLoaded();

            if ~obj.autoNDF || isempty(obj.ledCalibration)
                % --- Legacy behaviour: simple voltage doubling --------
                if obj.autoNDF
                    ndf = obj.startingNDF;
                else
                    ndf = obj.ndf;
                end
                for i = 1:n
                    v = obj.firstLightAmplitude * 2^(i - 1);
                    voltages(i) = v;
                    ndfs(i) = ndf;
                    if ~isempty(obj.ledCalibration)
                        fluxes(i) = obj.ledCalibration.voltageToFlux(obj.lightMean + v, ndf);
                    end
                end
                return;
            end

            % --- Auto-NDF: voltage doubling with NDF transitions ------
            cal = obj.ledCalibration;
            currentNdf = obj.startingNDF;

            % First pulse.
            voltages(1) = obj.firstLightAmplitude;
            ndfs(1)     = currentNdf;
            fluxes(1)   = cal.voltageToFlux(obj.lightMean + obj.firstLightAmplitude, currentNdf);

            for i = 2:n
                nextAmplitude = voltages(i - 1) * 2;

                if obj.lightMean + nextAmplitude <= 10.239
                    % Doubled voltage fits at current NDF — use it.
                    voltages(i) = nextAmplitude;
                    ndfs(i)     = currentNdf;
                    fluxes(i)   = cal.voltageToFlux(obj.lightMean + nextAmplitude, currentNdf);
                else
                    % Doubled voltage exceeds 10 V — switch NDF.
                    % Target: 2x the flux of the previous pulse.
                    prevFlux = fluxes(i - 1);
                    targetFlux = 2 * prevFlux;

                    warnState = warning('off', 'LEDCalibration:exceedsMax');
                    stepped = false;
                    ndfIdx = find(obj.NDF_VALUES == currentNdf, 1);
                    while ndfIdx > 1
                        ndfIdx = ndfIdx - 1;
                        candidateNdf = obj.NDF_VALUES(ndfIdx);
                        vTotal = cal.fluxToVoltage(targetFlux, candidateNdf);
                        if ~isnan(vTotal) && vTotal <= 10.239
                            currentNdf = candidateNdf;
                            stepped = true;
                            break;
                        end
                    end

                    if ~stepped
                        % Even NDF 0 can't deliver 2x flux. Clip.
                        currentNdf = 0;
                        vTotal = 10.239;
                        warning(warnState);
                        warning('CfPatchFlashFamily:fluxClipped', ...
                            'Pulse %d: target flux %.2e exceeds maximum at all NDFs. Clipping.', ...
                            i, targetFlux);
                    else
                        warning(warnState);
                    end

                    amplitude = max(0, vTotal - obj.lightMean);
                    voltages(i) = amplitude;
                    ndfs(i)     = currentNdf;
                    fluxes(i)   = cal.voltageToFlux(obj.lightMean + amplitude, currentNdf);
                end
            end
        end

        % ------------------------------------------------------------------
        %  Stimulus creation
        % ------------------------------------------------------------------

        function stim = createLedStimulus(obj, pulseNum)
            if obj.autoNDF && ~isempty(obj.ledCalibration)
                [voltages, ~, ~] = obj.computePulseTable();
                lightAmplitude = voltages(pulseNum);
            else
                lightAmplitude = obj.firstLightAmplitude * 2^(double(pulseNum) - 1);
            end

            gen = symphonyui.builtin.stimuli.PulseGenerator();

            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.amplitude = lightAmplitude;
            gen.mean = obj.lightMean;
            gen.sampleRate = obj.sampleRate;
            gen.units = obj.rig.getDevice(obj.led).background.displayUnits;

            stim = gen.generate();
        end

        function stim = createAmpTestPulseStimulus(obj)
            % Create a flat amp stimulus at background with a test pulse
            % embedded in pre-time for cell health monitoring.
            device = obj.rig.getDevice(obj.amp);
            bg = device.background.quantity;
            units = device.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            totalPts = timeToPts(obj.preTime + obj.stimTime + obj.tailTime);
            data = ones(1, totalPts) * bg;
            data = obj.embedTestPulse(data, obj.amp);
            stim = obj.createStimulusFromArray(data, units);
        end

        % ------------------------------------------------------------------
        %  Filter wheel helper
        % ------------------------------------------------------------------

        function setFilterWheelNDF(obj, ndf)
            % Set the filter wheel to the specified NDF value.
            % The caller is responsible for any settle-time pause.
            try
                devices = obj.rig.getDevices('FilterWheel');
                if ~isempty(devices)
                    devices{1}.setNDF(ndf);
                end
            catch e
                disp(['FilterWheel command failed: ' e.message]);
            end
        end

        % ------------------------------------------------------------------
        %  Epoch lifecycle
        % ------------------------------------------------------------------

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            pulseNum = mod(obj.numEpochsPrepared - 1, obj.pulsesInFamily) + 1;

            if obj.autoNDF && ~isempty(obj.ledCalibration)
                [voltages, ndfs, fluxes] = obj.computePulseTable();
                lightAmplitude = voltages(pulseNum);
                ndf = ndfs(pulseNum);

                epoch.addParameter('lightAmplitude', lightAmplitude);
                epoch.addParameter('ndf', ndf);
                epoch.addParameter('photonFluxPeak', fluxes(pulseNum));
                epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, ndf));
            else
                lightAmplitude = obj.firstLightAmplitude * 2^(double(pulseNum) - 1);
                ndf = obj.ndf;

                epoch.addParameter('lightAmplitude', lightAmplitude);
                epoch.addParameter('ndf', ndf);
                epoch.addParameter('photonFluxPeak', obj.getPhotonFlux(obj.lightMean + lightAmplitude, ndf));
                epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, ndf));
            end

            epoch.addParameter('pulseNum', pulseNum);

            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus(pulseNum));
            if obj.cellHealthEnabled()
                epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpTestPulseStimulus());
            end
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function completeEpoch(obj, epoch)
            completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            % Cell health metrics.
            if obj.cellHealthEnabled()
                try
                    testAmp = obj.testPulseAmplitude(obj.amp);
                    metrics = obj.computeCellHealthMetrics(epoch, obj.amp, testAmp, 5, 20);
                    obj.saveCellHealthMetrics(epoch, metrics);
                catch
                end
            end

            % Command the filter wheel HERE (at execution time, not
            % preparation time). The interval that follows this epoch
            % was already prepared with the correct duration (2 s for
            % NDF switches) during the preparation phase.
            if obj.autoNDF && ~isempty(obj.ledCalibration)
                [~, ndfs, ~] = obj.computePulseTable();

                thisNdf = epoch.parameters('ndf');

                nextPulse = mod(obj.numEpochsCompleted, obj.pulsesInFamily) + 1;
                nextNdf = ndfs(nextPulse);

                totalEpochs = double(obj.numberOfAverages) * double(obj.pulsesInFamily);
                if obj.numEpochsCompleted < totalEpochs && nextNdf ~= thisNdf
                    obj.setFilterWheelNDF(nextNdf);
                end
            end
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);

            obj.intervalCount = obj.intervalCount + 1;

            % Compute whether the upcoming epoch needs a different NDF.
            % If so, use a longer interval (4 s) to give the filter
            % wheel time to settle. The actual filter wheel COMMAND is
            % sent in completeEpoch (at execution time), not here
            % (preparation time), because Symphony pre-prepares all
            % epochs/intervals before any epoch plays on the DAQ.
            needsDelay = false;
            if obj.autoNDF && ~isempty(obj.ledCalibration)
                [~, ndfs, ~] = obj.computePulseTable();
                justFinishedPulse = mod(obj.intervalCount - 1, obj.pulsesInFamily) + 1;
                upcomingPulse     = mod(obj.intervalCount,     obj.pulsesInFamily) + 1;
                needsDelay = (ndfs(justFinishedPulse) ~= ndfs(upcomingPulse));
            end

            if needsDelay
                duration = max(obj.interpulseInterval, 4);
            else
                duration = obj.interpulseInterval;
            end

            % Hold LED at background during inter-pulse interval.
            ledDevice = obj.rig.getDevice(obj.led);
            interval.addDirectCurrentStimulus(ledDevice, ledDevice.background, duration, obj.sampleRate);

            % Hold amplifier at background during inter-pulse interval.
            ampDevice = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(ampDevice, ampDevice.background, duration, obj.sampleRate);
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function [tf, msg] = isValid(obj)
            [tf, msg] = isValid@fortenbachlab.protocols.FortenbachLabProtocol(obj);
            if ~tf
                return;
            end

            if ~obj.autoNDF
                % Legacy check: ensure the last pulse doesn't overflow.
                units = obj.rig.getDevice(obj.led).background.displayUnits;
                amplitude = obj.firstLightAmplitude * 2^(double(obj.pulsesInFamily) - 1);
                if (strcmp(units, symphonyui.core.Measurement.NORMALIZED) && amplitude > 1) ...
                        || (strcmp(units, 'V') && amplitude > 10.239)
                    tf = false;
                    msg = 'Last pulse amplitude too large';
                end
            else
                % Check whether any pulse in the family would exceed the
                % LED's 10 V limit even at NDF 0.
                try
                    warnState = warning('off', 'LEDCalibration:exceedsMax');
                    [voltages, ndfs, ~] = obj.computePulseTable();
                    warning(warnState);
                    lastIdx = find(ndfs == 0 & voltages >= (10.239 - obj.lightMean), 1);
                    if ~isempty(lastIdx)
                        tf = false;
                        msg = sprintf(['Pulse %d exceeds LED max at NDF 0. ' ...
                            'Reduce pulsesInFamily or increase startingNDF.'], lastIdx);
                    end
                catch
                end
            end
        end

        % ------------------------------------------------------------------
        %  Dependent property getters / setters
        % ------------------------------------------------------------------

        function a = get.amp2(obj)
            amps = obj.rig.getDeviceNames('Amp');
            if numel(amps) < 2
                a = '(None)';
            else
                i = find(~ismember(amps, obj.amp), 1);
                a = amps{i};
            end
        end

        function s = get.photonFluxPeakMin(obj)
            % Photon flux at the first (dimmest) pulse.
            try
                warnState = warning('off', 'LEDCalibration:exceedsMax');
                [voltages, ndfs, fluxes] = obj.computePulseTable();
                warning(warnState);
                f = fluxes(1);
                if f == 0
                    fStr = '0';
                else
                    exponent = floor(log10(abs(f)));
                    mantissa = f / 10^exponent;
                    fStr = sprintf('%.2fe%+03d', mantissa, exponent);
                end
                s = sprintf('%s ph/cm2/s  (%.2fV, NDF %.1f)', fStr, voltages(1), ndfs(1));
            catch
                s = 'N/A';
            end
        end

        function set.photonFluxPeakMin(obj, val)
            % Parse a scientific-notation string (or number) and invert
            % the calibration to find the LED voltage needed to deliver
            % that flux for the first pulse. Sets firstLightAmplitude
            % accordingly.
            if isnumeric(val)
                targetFlux = double(val);
            elseif ischar(val) || isstring(val)
                str = strtrim(char(val));
                tok = regexp(str, '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?', 'match', 'once');
                if isempty(tok)
                    return;
                end
                targetFlux = str2double(tok);
            else
                return;
            end
            if isempty(targetFlux) || ~isfinite(targetFlux) || targetFlux < 0
                return;
            end
            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration)
                warning('CfPatchFlashFamily:NoCalibration', ...
                    'LED calibration not loaded; cannot set photonFluxPeakMin.');
                return;
            end
            if obj.autoNDF
                % Find the highest NDF (most attenuation) that can still
                % deliver the target flux within the LED's 10 V range.
                warnState = warning('off', 'LEDCalibration:exceedsMax');
                bestNdf = [];
                bestV   = NaN;
                for k = numel(obj.NDF_VALUES):-1:1
                    candidateNdf = obj.NDF_VALUES(k);
                    v = obj.ledCalibration.fluxToVoltage(targetFlux, candidateNdf);
                    if ~isnan(v) && v <= 10.239
                        bestNdf = candidateNdf;
                        bestV   = v;
                        break;
                    end
                end
                warning(warnState);

                if isempty(bestNdf)
                    warning('CfPatchFlashFamily:fluxTooHigh', ...
                        'Target flux %.2e exceeds maximum at all NDFs. Clamping to max.', targetFlux);
                    bestNdf = 0;
                    bestV   = 10.239;
                end

                obj.startingNDF = bestNdf;
                vPeak = bestV;
            else
                warnState = warning('off', 'LEDCalibration:exceedsMax');
                vPeak = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf);
                warning(warnState);
                if isnan(vPeak)
                    warning('CfPatchFlashFamily:fluxTooHigh', ...
                        'Target flux %.2e exceeds maximum at NDF %.1f. Clamping to max voltage.', targetFlux, obj.ndf);
                    vPeak = 10.239;
                end
            end
            newAmplitude = vPeak - obj.lightMean;
            if newAmplitude < 0
                newAmplitude = 0;
            end
            obj.firstLightAmplitude = newAmplitude;
        end

        function s = get.photonFluxPeakMax(obj)
            % Photon flux at the last (brightest) pulse.
            try
                warnState = warning('off', 'LEDCalibration:exceedsMax');
                [voltages, ndfs, fluxes] = obj.computePulseTable();
                warning(warnState);
                f = fluxes(end);
                if f == 0
                    fStr = '0';
                else
                    exponent = floor(log10(abs(f)));
                    mantissa = f / 10^exponent;
                    fStr = sprintf('%.2fe%+03d', mantissa, exponent);
                end
                s = sprintf('%s ph/cm2/s  (%.2fV, NDF %.1f)', fStr, voltages(end), ndfs(end));
            catch
                s = 'N/A';
            end
        end

        function s = get.photonFluxBackground(obj)
            try
                if obj.autoNDF
                    ndf = obj.startingNDF;
                else
                    ndf = obj.ndf;
                end
                s = obj.getPhotonFluxString(obj.lightMean, ndf);
            catch
                s = 'N/A';
            end
        end

    end

end
