classdef CfMeaFlashTrain < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents a periodic train of rectangular LED flashes at a specified
    % frequency for a specified total duration, recording from a specified
    % amplifier (MEA). Derived from CfMeaFlash.
    %
    % One epoch = preTime + train + tailTime. Within the train, a flash of
    % stimTime ms is delivered every 1/stimFrequency seconds, starting at
    % the beginning of the train. stimTime is automatically limited to HALF
    % the flash period (500/stimFrequency ms), i.e. light-on time is at most
    % equal to light-off time within each cycle: entering a longer value, or
    % raising the frequency so the current value no longer fits, clamps it.
    %
    % The amplifier/MEA channel carries the same train (scaled for the MEA)
    % plus the three-pulse NDF marker at the start of preTime, as in
    % CfMeaFlash. preTime must be >= 45 ms so the marker does not overlap
    % the first flash.

    properties
        led                             % Output LED
        amp                             % Output amplifier
        preTime = 500                   % Baseline before the train (ms)
        stimFrequency = 1               % Flash frequency (Hz)
        stimTime = 100                  % Flash duration (ms); clamped to <= 500/stimFrequency (<= 50% duty)
        totalDuration = 60              % Total train duration (s)
        tailTime = 500                  % Baseline after the train (ms)
        lightAmplitude = 1              % Flash amplitude (V [0-10])
        pulseAmplitude = 1              % Voltage Output (Auto-calculated DO NOT ADJUST to avoid MEA overload)
        lightMean = 0                   % Background amplitude: LED DC voltage (V or norm. [0-1])
        ndf = 0.0                       % ND filter setting (applied to filter wheel at run start)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
        backgroundIntensity             % Background intensity (photons/cm2/s)
        flashCount                      % Number of flashes in the train (auto)
        epochDuration                   % Total epoch duration incl. pre/tail (s, auto)
    end

    properties (Dependent)
        flashIntensity                  % Flash intensity (photons/cm2/s). Accepts scientific notation, e.g. '1.5e15'.
    end

    properties (Hidden)
        ledType
        ampType
        ndfType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
    end

    properties (Constant, Hidden)
        MIN_PRETIME_MS = 45             % NDF marker occupies the first 40 ms of preTime
    end

    methods

        function obj = CfMeaFlashTrain()
            obj.objective = '4x';
        end

        % When delivering voltage steps, 50 mV command results in 1 mV voltage step and max input voltage of MEA is 4 volts.
        function pulseAmplitudeCut = get.pulseAmplitude(obj)
            pulseAmplitudeCut = obj.lightAmplitude * 1000 * 0.4 / 50;
        end

        % ---- Frequency / duration coupling -------------------------------

        function set.stimFrequency(obj, f)
            if ~isscalar(f) || ~isfinite(f) || f <= 0
                warning('CfMeaFlashTrain:badFrequency', 'stimFrequency must be a positive finite scalar (Hz); ignoring %g.', f);
                return;
            end
            obj.stimFrequency = double(f);
            obj.clampStimTime();
        end

        function set.stimTime(obj, t)
            if ~isscalar(t) || ~isfinite(t) || t <= 0
                warning('CfMeaFlashTrain:badStimTime', 'stimTime must be a positive finite scalar (ms); ignoring %g.', t);
                return;
            end
            obj.stimTime = double(t);
            obj.clampStimTime();
        end

        function set.preTime(obj, t)
            if t < obj.MIN_PRETIME_MS
                warning('CfMeaFlashTrain:preTimeTooShort', ...
                    'preTime raised to %g ms so the NDF marker fits before the first flash.', obj.MIN_PRETIME_MS);
                t = obj.MIN_PRETIME_MS;
            end
            obj.preTime = double(t);
        end

        function p = flashPeriodMs(obj)
            p = 1000 / obj.stimFrequency;
        end

        function m = maxStimTimeMs(obj)
            % Longest permitted flash: half the period (ON time <= OFF time).
            m = obj.flashPeriodMs() / 2;
        end

        function n = get.flashCount(obj)
            % Flashes whose onset falls within the train.
            n = floor(obj.totalDuration * obj.stimFrequency + 1e-9);
        end

        function d = get.epochDuration(obj)
            d = (obj.preTime + obj.tailTime) / 1e3 + obj.totalDuration;
        end

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
                case 'stimFrequency'
                    d.category = 'Stimulus';
                    d.displayName = 'Flash Frequency (Hz)';
                case 'stimTime'
                    d.category = 'Stimulus';
                    d.displayName = sprintf('Flash Duration (ms, max %.4g = 50%% duty)', obj.maxStimTimeMs());
                case 'totalDuration'
                    d.category = 'Stimulus';
                    d.displayName = 'Total Duration (s)';
                case 'tailTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Tail Time (ms)';
                case 'flashCount'
                    d.category = 'Stimulus';
                    d.displayName = 'Flash Count (auto)';
                case 'epochDuration'
                    d.category = 'Stimulus';
                    d.displayName = 'Epoch Duration (s, auto)';
                case 'led'
                    d.category = 'Light';
                case 'lightAmplitude'
                    d.category = 'Light';
                    d.displayName = 'Flash Amplitude (V)';
                case 'lightMean'
                    d.category = 'Light';
                    d.displayName = 'Background Voltage (V)';
                case 'ndf'
                    d.category = 'Light';
                    d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', ...
                        {0, 0.5, 1.0, 2.0, 3.0, 4.0});
                case 'flashIntensity'
                    d.category = 'Light';
                    d.type = symphonyui.core.PropertyType('char', 'row');
                case 'backgroundIntensity'
                    d.category = 'Light';
                case 'pulseAmplitude'
                    d.isHidden = true;
            end

            if strncmp(name, 'amp2', 4) && numel(obj.rig.getDeviceNames('Amp')) < 2
                d.isHidden = true;
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()obj.createLedStimulus());
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            obj.setLedBackground(obj.led, obj.lightMean);

            % Move the filter wheel to the selected NDF. If the NDF is
            % actually changing, wait for the wheel to physically settle
            % before starting any epochs.
            try
                fws = obj.rig.getDevices('FilterWheel');
                if ~isempty(fws)
                    currentNDF = fws{1}.getConfigurationSetting('NDF');
                    fws{1}.setNDF(obj.ndf);
                    if ~isequal(currentNDF, obj.ndf)
                        pause(4);  % filter wheel settle time
                    end
                end
            catch e
                warning('CfMeaFlashTrain:setNDFFailed', ...
                    'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
            end

            obj.showFigure('fortenbachlab.figures.ProgressFigure', 1, ...
                'flashVoltages', obj.lightAmplitude, ...
                'flashNdfs', obj.ndf, ...
                'flashFluxes', obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, obj.ndf));
        end

        % ---- Waveforms -----------------------------------------------------

        function [mask, prePts, trainPts, tailPts] = flashMask(obj)
            % Logical mask of flash-ON samples over the whole epoch.
            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            prePts   = timeToPts(obj.preTime);
            trainPts = round(obj.totalDuration * obj.sampleRate);
            tailPts  = timeToPts(obj.tailTime);
            stimPts  = timeToPts(obj.stimTime);
            periodPts = obj.sampleRate / obj.stimFrequency;   % may be non-integer

            mask = false(1, prePts + trainPts + tailPts);
            for k = 0:obj.flashCount - 1
                onset = prePts + round(k * periodPts) + 1;
                offset = min(onset + stimPts - 1, prePts + trainPts);  % never extend into the tail
                if onset <= prePts + trainPts
                    mask(onset:offset) = true;
                end
            end
        end

        function LEDstim = createLedStimulus(obj)
            mask = obj.flashMask();
            data = ones(size(mask)) * obj.lightMean;
            data(mask) = obj.lightMean + obj.lightAmplitude;
            units = obj.rig.getDevice(obj.led).background.displayUnits;
            LEDstim = obj.createStimulusFromArray(data, units);
        end

        function Ampstim = createAmpStimulus(obj, ndf)
            ampDevice = obj.rig.getDevice(obj.amp);
            background = ampDevice.background.quantity;
            units = ampDevice.background.displayUnits;

            mask = obj.flashMask();
            data = ones(size(mask)) * background;
            data(mask) = background + obj.pulseAmplitude;

            % NDF encoding: three 10-ms pulses [marker, NDF, marker] scaled
            % by the same x8 MEA factor used for the stimulus amplitude.
            % Marker value of 1 V -> 8 V on MCS (within DAC range).
            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            meaScale = 1000 * 0.4 / 50;
            pulsePts = timeToPts(10);  % 10 ms per step
            gapPts  = timeToPts(5);   % 5 ms blank between steps
            idx = 1;
            data(idx : idx+pulsePts-1)           = 1   * meaScale;  idx = idx + pulsePts + gapPts;
            data(idx : idx+pulsePts-1)           = ndf * meaScale;  idx = idx + pulsePts + gapPts;
            data(idx : idx+pulsePts-1)           = 1   * meaScale;

            Ampstim = obj.createStimulusFromArray(data, units);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            ndf = obj.ndf;

            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
            epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpStimulus(ndf));
            epoch.addResponse(obj.rig.getDevice(obj.amp));
            epoch.addParameter('ndf', ndf);
            epoch.addParameter('stimFrequency_Hz', obj.stimFrequency);
            epoch.addParameter('flashDuration_ms', obj.stimTime);
            epoch.addParameter('flashPeriod_ms', obj.flashPeriodMs());
            epoch.addParameter('flashDutyCycle', obj.stimTime / obj.flashPeriodMs());
            epoch.addParameter('flashCount', obj.flashCount);
            epoch.addParameter('trainDuration_s', obj.totalDuration);
            epoch.addParameter('photonFluxPeak', obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, ndf));
            epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, ndf));

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < 1;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < 1;
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

        function s = get.flashIntensity(obj)
            % Return the peak flux as a scientific-notation string.
            try
                f = obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, obj.ndf);
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

        function set.flashIntensity(obj, val)
            % Parse the user-entered string (scientific notation OK) and
            % invert the calibration to find the required LED voltage at the
            % current NDF, then update lightAmplitude.
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
                warning('CfMeaFlashTrain:NoCalibration', ...
                    'LED calibration not loaded; cannot set flashIntensity.');
                return;
            end
            vPeak = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf, obj.objective);
            if isnan(vPeak)
                vPeak = 10;  % clamp to max
            end
            newAmplitude = vPeak - obj.lightMean;
            if newAmplitude < 0
                newAmplitude = 0;
            end
            obj.lightAmplitude = newAmplitude;
        end

        function s = get.backgroundIntensity(obj)
            try
                if obj.lightMean == 0
                    s = '0';
                    return;
                end
                s = obj.getPhotonFluxString(obj.lightMean, obj.ndf);
            catch
                s = 'N/A';
            end
        end

    end

    methods (Access = private)

        function clampStimTime(obj)
            % Keep light-on time <= light-off time: flash <= half the period.
            % Guarded so it is a no-op before both properties are initialized.
            if isempty(obj.stimFrequency) || isempty(obj.stimTime)
                return;
            end
            maxStim = obj.maxStimTimeMs();
            if obj.stimTime > maxStim
                warning('CfMeaFlashTrain:stimTimeClamped', ...
                    'Flash duration %g ms exceeds half the %g Hz period (%g ms); set to %g ms so ON time <= OFF time.', ...
                    obj.stimTime, obj.stimFrequency, obj.flashPeriodMs(), maxStim);
                obj.stimTime = maxStim;   % re-enters set.stimTime; no further clamp needed
            end
        end

    end

end
