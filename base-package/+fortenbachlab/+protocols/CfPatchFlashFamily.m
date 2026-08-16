classdef CfPatchFlashFamily < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents families of escalating-intensity flash stimuli to an LED and
    % records from an amplifier in voltage-clamp or current-clamp mode.
    %
    % Each family consists of pulsesInFamily flashes ordered dim to bright.
    % When autoNDF is enabled, the protocol works backward from maximum
    % intensity: the brightest pulse is MAX_LED_VOLTAGE at NDF 0, and each
    % preceding pulse targets half the flux. When voltage would drop below
    % MIN_LED_VOLTAGE, the filter wheel switches to a higher NDF (more
    % attenuation) to restore DAC resolution.
    %
    % When autoNDF is off, voltage doubles each step at the current NDF
    % (legacy behaviour).
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
    %   - Flash intensity display and entry in scientific notation
    %   - Hardware-timed filter wheel settle delay (2 s via prepareInterval)
    %   - Dual amplifier support

    properties
        led                             % Output LED
        preTime = 100                   % Pulse leading duration (ms)
        stimTime = 10                   % Pulse duration (ms)
        tailTime = 3000                 % Pulse trailing duration (ms)
        firstLightAmplitude = 0.02      % First flash amplitude (V [0-10])
        pulsesInFamily = uint16(10)     % Number of flash intensities
        lightMean = 0                   % Background amplitude: LED DC voltage (V)
        ndf = 0.0                       % ND filter setting (when autoNDF is off)
        autoNDF = true                  % Automatically switch NDF when voltage exceeds 10 V
        startingNDF = 4.0               % Starting NDF value (used when autoNDF is true)
        numberOfAverages = uint16(5)    % Number of family repeats
        interpulseInterval = 0          % Duration between pulses (s)
        amp                             % Input amplifier
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Dependent)
        flashIntensityMin               % Flash intensity at dimmest pulse. Accepts scientific notation.
        flashIntensityMax               % Flash intensity at brightest pulse. Accepts scientific notation.
        backgroundIntensity            % Background intensity (photons/cm2/s). Accepts scientific notation.
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
        cachedNdfs = []         % NDF values for each pulse (cached in prepareRun to avoid recomputing in callbacks)
        anchorEnd = 'max'       % 'min' or 'max' — which intensity end the user anchored
        anchorFlux = NaN        % Target flux at anchor end; NaN = use default (10V @ NDF0)
    end

    properties (Constant, Hidden)
        NDF_VALUES = [0 0.5 1.0 2.0 3.0 4.0];  % Available NDF positions (ascending)
        MAX_LED_VOLTAGE = 10;       % Maximum LED command voltage (V)
        MIN_LED_VOLTAGE = 0.5;      % Minimum usable voltage for good DAC resolution
    end

    methods

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            [obj.led, obj.ledType] = obj.createDeviceNamesProperty('LED');
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.FortenbachLabProtocol(obj, name);

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
                case 'pulsesInFamily'
                    d.category = 'Stimulus';
                    d.displayName = 'Pulses In Family';
                case 'led'
                    d.category = 'Light';
                case 'firstLightAmplitude'
                    d.category = 'Light';
                    d.displayName = 'First Flash Amplitude (V)';
                    if obj.autoNDF
                        d.isHidden = true;
                    end
                case 'lightMean'
                    d.category = 'Light';
                    d.displayName = 'Background Voltage (V)';
                case 'ndf'
                    d.category = 'Light';
                    d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', ...
                        {0, 0.5, 1.0, 2.0, 3.0, 4.0});
                    if obj.autoNDF
                        d.isHidden = true;
                    end
                case 'autoNDF'
                    d.category = 'Light';
                case 'startingNDF'
                    d.category = 'Light';
                    d.isHidden = true;
                case 'flashIntensityMin'
                    d.category = 'Light';
                    d.type = symphonyui.core.PropertyType('char', 'row');
                case 'flashIntensityMax'
                    d.category = 'Light';
                    d.type = symphonyui.core.PropertyType('char', 'row');
                case 'backgroundIntensity'
                    d.category = 'Light';
                    d.type = symphonyui.core.PropertyType('char', 'row');
                case 'amp'
                    d.category = 'Amplifier';
                case 'amp2'
                    d.category = 'Amplifier';
                case 'numberOfAverages'
                    d.category = 'Acquisition';
                    d.displayName = 'Number of Averages';
                case 'interpulseInterval'
                    d.category = 'Acquisition';
                    d.displayName = 'Interpulse Interval (s)';
            end

            if strncmp(name, 'amp2', 4) && numel(obj.rig.getDeviceNames('Amp')) < 2
                d.isHidden = true;
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

            % Set filter wheel to the NDF of the first (dimmest) pulse.
            % Cache the NDF table so completeEpoch/prepareInterval can use
            % it without recomputing (saves ~0.5-1 s of MATLAB processing
            % per callback, which matters because the CompletedEpoch event
            % fires asynchronously — the DAQ starts the next interval
            % while MATLAB is still in the callback).
            if obj.autoNDF
                [~, tableNdfs, ~] = obj.computePulseTable();
                obj.cachedNdfs = tableNdfs;
                firstNdf = tableNdfs(1);
                try
                    fws = obj.rig.getDevices('FilterWheel');
                    if ~isempty(fws)
                        currentNDF = fws{1}.getConfigurationSetting('NDF');
                        obj.setFilterWheelNDF(firstNdf);
                        if ~isequal(currentNDF, firstNdf)
                            pause(6);
                        end
                    end
                catch
                    obj.setFilterWheelNDF(firstNdf);
                    pause(6);
                end
                obj.lastNdf = firstNdf;
            else
                % Set filter wheel to selected NDF with settle time.
                try
                    fws = obj.rig.getDevices('FilterWheel');
                    if ~isempty(fws)
                        currentNDF = fws{1}.getConfigurationSetting('NDF');
                        fws{1}.setNDF(obj.ndf);
                        if ~isequal(currentNDF, obj.ndf)
                            pause(6);
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
            % COMPUTEPULSETABLE  Pre-compute voltage, NDF, and flash intensity
            % for every pulse in the family.
            %
            % When autoNDF is false: voltage doubles each step at the
            % current NDF setting.
            %
            % When autoNDF is true the family is a doubling series of
            % photon fluxes.  The user can anchor either end:
            %   - anchorEnd='max': family works downward from max flux.
            %   - anchorEnd='min': family works upward from min flux.
            %   - anchorFlux=NaN (default): max is MAX_LED_VOLTAGE at NDF 0.
            %
            % The algorithm resolves each target flux to a (voltage, NDF)
            % pair, switching NDFs to maintain DAC resolution:
            %   - Too dim  → step UP to higher NDF (more voltage needed).
            %   - Too bright → step DOWN to lower NDF.
            % Result is ordered dim (index 1) to bright (index N).

            n = double(obj.pulsesInFamily);
            voltages = zeros(1, n);
            ndfs     = zeros(1, n);
            fluxes   = zeros(1, n);

            obj.ensureCalibrationLoaded();

            if ~obj.autoNDF || isempty(obj.ledCalibration)
                % --- Legacy behaviour: simple voltage doubling --------
                ndf = obj.ndf;
                for i = 1:n
                    v = obj.firstLightAmplitude * 2^(i - 1);
                    voltages(i) = v;
                    ndfs(i) = ndf;
                    if ~isempty(obj.ledCalibration)
                        fluxes(i) = obj.ledCalibration.voltageToFlux(obj.lightMean + v, ndf, obj.objective);
                    end
                end
                return;
            end

            % --- Auto-NDF mode ----------------------------------------
            cal = obj.ledCalibration;

            % Step 1: Build the target flux array (doubling series).
            targetFluxes = zeros(1, n);
            if ~isnan(obj.anchorFlux) && strcmp(obj.anchorEnd, 'min')
                % Family anchored at user-specified minimum — build upward.
                for i = 1:n
                    targetFluxes(i) = obj.anchorFlux * 2^(i - 1);
                end
            elseif ~isnan(obj.anchorFlux) && strcmp(obj.anchorEnd, 'max')
                % Family anchored at user-specified maximum — build downward.
                for i = 1:n
                    targetFluxes(i) = obj.anchorFlux / 2^(n - i);
                end
            else
                % Default: maximum is MAX_LED_VOLTAGE at NDF 0.
                maxFlux = cal.voltageToFlux(obj.lightMean + obj.MAX_LED_VOLTAGE, 0, obj.objective);
                for i = 1:n
                    targetFluxes(i) = maxFlux / 2^(n - i);
                end
            end

            % Step 2: Find the starting NDF — scan from highest
            % attenuation downward to find usable DAC resolution for
            % the dimmest pulse.
            currentNdf = obj.NDF_VALUES(end);
            warnState = warning('off', 'LEDCalibration:exceedsMax');
            for ndfIdx = numel(obj.NDF_VALUES):-1:1
                candidateNdf = obj.NDF_VALUES(ndfIdx);
                vTotal = cal.fluxToVoltage(targetFluxes(1), candidateNdf, obj.objective);
                amp_ = vTotal - obj.lightMean;
                if ~isnan(vTotal) && amp_ >= obj.MIN_LED_VOLTAGE ...
                        && amp_ <= obj.MAX_LED_VOLTAGE
                    currentNdf = candidateNdf;
                    break;
                end
            end
            warning(warnState);

            % Step 3: Resolve each pulse to voltage + NDF.  Walk dim
            % to bright, stepping to lower NDFs (less attenuation)
            % when voltage would exceed MAX_LED_VOLTAGE.
            for i = 1:n
                warnState = warning('off', 'LEDCalibration:exceedsMax');
                vTotal = cal.fluxToVoltage(targetFluxes(i), currentNdf, obj.objective);
                warning(warnState);
                amplitude = vTotal - obj.lightMean;

                if ~isnan(vTotal) && amplitude >= obj.MIN_LED_VOLTAGE ...
                        && amplitude <= obj.MAX_LED_VOLTAGE
                    % Good resolution at current NDF.
                    voltages(i) = amplitude;
                    ndfs(i)     = currentNdf;

                elseif isnan(vTotal) || amplitude > obj.MAX_LED_VOLTAGE
                    % Too bright or exceeds calibration max — step to
                    % lower NDF (less attenuation).  NaN from
                    % fluxToVoltage means the target flux exceeds what
                    % the LED can produce at this NDF.
                    stepped = false;
                    nIdx = find(obj.NDF_VALUES == currentNdf, 1);
                    warnState = warning('off', 'LEDCalibration:exceedsMax');
                    while nIdx > 1
                        nIdx = nIdx - 1;
                        cNdf = obj.NDF_VALUES(nIdx);
                        vTotal = cal.fluxToVoltage(targetFluxes(i), cNdf, obj.objective);
                        amplitude = vTotal - obj.lightMean;
                        if ~isnan(vTotal) && amplitude >= obj.MIN_LED_VOLTAGE ...
                                && amplitude <= obj.MAX_LED_VOLTAGE
                            currentNdf = cNdf;
                            stepped = true;
                            break;
                        end
                    end
                    warning(warnState);
                    if ~stepped
                        currentNdf = obj.NDF_VALUES(1);
                        amplitude  = obj.MAX_LED_VOLTAGE;
                    end
                    voltages(i) = amplitude;
                    ndfs(i)     = currentNdf;

                else
                    % Too dim — step to higher NDF (more attenuation,
                    % higher voltage needed for same flux).
                    stepped = false;
                    nIdx = find(obj.NDF_VALUES == currentNdf, 1);
                    warnState = warning('off', 'LEDCalibration:exceedsMax');
                    while nIdx < numel(obj.NDF_VALUES)
                        nIdx = nIdx + 1;
                        cNdf = obj.NDF_VALUES(nIdx);
                        vTotal = cal.fluxToVoltage(targetFluxes(i), cNdf, obj.objective);
                        amplitude = vTotal - obj.lightMean;
                        if ~isnan(vTotal) && amplitude >= obj.MIN_LED_VOLTAGE
                            currentNdf = cNdf;
                            stepped = true;
                            break;
                        end
                    end
                    warning(warnState);
                    if ~stepped
                        currentNdf = obj.NDF_VALUES(end);
                        amplitude  = obj.MIN_LED_VOLTAGE;
                        warning('CfPatchFlashFamily:lowResolution', ...
                            'Pulse %d: voltage %.3fV at NDF %.1f below min threshold.', ...
                            i, amplitude, currentNdf);
                    end
                    voltages(i) = amplitude;
                    ndfs(i)     = currentNdf;
                end

                fluxes(i) = cal.voltageToFlux(obj.lightMean + voltages(i), ndfs(i), obj.objective);
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
            % CRITICAL TIMING: Send the filter wheel command FIRST,
            % before the superclass call and cell health metrics. The
            % superclass updateFigures() processes all response data
            % and redraws every plot — that can take hundreds of ms.
            % Cell health computes response metrics — more delay.
            % Meanwhile the C# DAQ has already started the next
            % interval. If we wait too long, the interval ends and
            % the next epoch starts before the wheel has settled.
            %
            % numEpochsCompleted hasn't been incremented yet (the
            % superclass does that), so we use +1 here.
            if obj.autoNDF && ~isempty(obj.cachedNdfs)
                thisNdf = epoch.parameters('ndf');

                nextPulse = mod(obj.numEpochsCompleted + 1, obj.pulsesInFamily) + 1;
                nextNdf = obj.cachedNdfs(nextPulse);

                totalEpochs = double(obj.numberOfAverages) * double(obj.pulsesInFamily);
                if (obj.numEpochsCompleted + 1) < totalEpochs && nextNdf ~= thisNdf
                    obj.setFilterWheelNDF(nextNdf);
                end
            end

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
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);

            obj.intervalCount = obj.intervalCount + 1;

            % Compute whether the upcoming epoch needs a different NDF.
            % If so, use a longer interval (6 s) to give the filter
            % wheel time to settle. The extra margin accounts for the
            % fact that the filter wheel command (sent in completeEpoch)
            % fires asynchronously — MATLAB processing in the callback
            % eats ~0.5-1 s before the USB command is dispatched, and
            % large NDF jumps can take 3-4 s of physical wheel movement.
            needsDelay = false;
            if obj.autoNDF && ~isempty(obj.cachedNdfs)
                justFinishedPulse = mod(obj.intervalCount - 1, obj.pulsesInFamily) + 1;
                upcomingPulse     = mod(obj.intervalCount,     obj.pulsesInFamily) + 1;
                needsDelay = (obj.cachedNdfs(justFinishedPulse) ~= obj.cachedNdfs(upcomingPulse));
            end

            if needsDelay
                duration = max(obj.interpulseInterval, 6);
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
            end
            % When autoNDF is on, the table is valid by construction:
            % brightest pulse is always MAX_LED_VOLTAGE at NDF 0.
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

        function s = get.flashIntensityMin(obj)
            % Flash intensity at the first (dimmest) pulse.
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

        function set.flashIntensityMin(obj, val)
            targetFlux = obj.parseFluxInput(val);
            if isempty(targetFlux); return; end

            if obj.autoNDF
                % Anchor the family at the minimum — max is computed
                % as min * 2^(N-1).
                obj.anchorEnd  = 'min';
                obj.anchorFlux = targetFlux;
                % Resolve and sync firstLightAmplitude so that
                % Symphony detects the property change and refreshes
                % all dependent properties in the UI.
                obj.ensureCalibrationLoaded();
                if ~isempty(obj.ledCalibration)
                    [voltages, ~, ~] = obj.computePulseTable();
                    obj.firstLightAmplitude = voltages(1);
                end
                return;
            end

            % Legacy mode: invert calibration to set firstLightAmplitude.
            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration); return; end
            warnState = warning('off', 'LEDCalibration:exceedsMax');
            vPeak = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf, obj.objective);
            warning(warnState);
            if isnan(vPeak); vPeak = 10.239; end
            newAmplitude = max(0, vPeak - obj.lightMean);
            obj.firstLightAmplitude = newAmplitude;
        end

        function s = get.flashIntensityMax(obj)
            % Flash intensity at the last (brightest) pulse.
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

        function set.flashIntensityMax(obj, val)
            targetFlux = obj.parseFluxInput(val);
            if isempty(targetFlux); return; end

            if obj.autoNDF
                % Anchor the family at the maximum — min is computed
                % as max / 2^(N-1).
                obj.anchorEnd  = 'max';
                obj.anchorFlux = targetFlux;
                % Resolve and sync firstLightAmplitude so that
                % Symphony detects the property change and refreshes
                % all dependent properties in the UI.
                obj.ensureCalibrationLoaded();
                if ~isempty(obj.ledCalibration)
                    [voltages, ~, ~] = obj.computePulseTable();
                    obj.firstLightAmplitude = voltages(1);
                end
                return;
            end

            % Legacy mode: compute firstLightAmplitude from max.
            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration); return; end
            warnState = warning('off', 'LEDCalibration:exceedsMax');
            vPeak = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf, obj.objective);
            warning(warnState);
            if isnan(vPeak); vPeak = 10.239; end
            maxAmplitude = max(0, vPeak - obj.lightMean);
            obj.firstLightAmplitude = maxAmplitude / 2^(double(obj.pulsesInFamily) - 1);
        end

        function s = get.backgroundIntensity(obj)
            try
                if obj.lightMean == 0
                    s = '0';
                    return;
                end
                if obj.autoNDF && ~isempty(obj.ledCalibration)
                    [~, tableNdfs, ~] = obj.computePulseTable();
                    ndf = tableNdfs(1);  % NDF at start of run (dimmest pulse)
                else
                    ndf = obj.ndf;
                end
                s = obj.getPhotonFluxString(obj.lightMean, ndf);
            catch
                s = 'N/A';
            end
        end

        function set.backgroundIntensity(obj, val)
            targetFlux = obj.parseFluxInput(val);
            if isempty(targetFlux); return; end

            if targetFlux == 0
                obj.lightMean = 0;
                return;
            end

            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration); return; end

            % Use NDF 0 as reference for background voltage.  The
            % physical background flux varies with filter wheel
            % position, but the LED voltage is constant.
            ndf = 0;
            if ~obj.autoNDF
                ndf = obj.ndf;
            end
            warnState = warning('off', 'LEDCalibration:exceedsMax');
            vTotal = obj.ledCalibration.fluxToVoltage(targetFlux, ndf, obj.objective);
            warning(warnState);
            if isnan(vTotal) || vTotal < 0; return; end
            obj.lightMean = vTotal;
        end

    end

    methods (Static, Access = private)

        function targetFlux = parseFluxInput(val)
            %PARSEFLUXINPUT  Parse a numeric or scientific-notation string
            %   into a photon-flux value.  Returns [] on invalid input.
            if isnumeric(val)
                targetFlux = double(val);
            elseif ischar(val) || isstring(val)
                str = strtrim(char(val));
                tok = regexp(str, '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?', ...
                    'match', 'once');
                if isempty(tok)
                    targetFlux = [];
                    return;
                end
                targetFlux = str2double(tok);
            else
                targetFlux = [];
                return;
            end
            if isempty(targetFlux) || ~isfinite(targetFlux) || targetFlux < 0
                targetFlux = [];
            end
        end

    end

end
