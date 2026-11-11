classdef CfPatchStepHz < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents rectangular pulse stimuli to a specified amplifier at a fixed
    % step frequency and records from the same amplifier. Derived from
    % CfPatchStep.
    %
    % Each epoch is one step cycle of length 1000/stepFrequency ms:
    %     preTime + stimTime + tailTime = 1000 / stepFrequency
    % preTime and stimTime are entered; tailTime is computed. Epochs are
    % queued back-to-back with no inter-epoch interval, so successive step
    % onsets are exactly one period apart. If preTime + stimTime exceeds the
    % period, the protocol refuses to run (and the preview fails) with an
    % error stating the maximum allowed.

    properties
        amp                             % Output amplifier
        stepFrequency = 1               % Step frequency (Hz); period = 1000/stepFrequency ms
        preTime = 100                   % Pulse leading duration (ms)
        stimTime = 500                  % Pulse duration (ms)
        pulseAmplitude = 100            % Pulse amplitude (mV or pA depending on amp mode)
    end

    properties (Dependent, SetAccess = private)
        tailTime                        % Pulse trailing duration (ms) = period - preTime - stimTime (auto)
        amp2                            % Secondary amplifier
    end

    properties
        amp2PulseAmplitude = 0          % Pulse amplitude for secondary amp (mV or pA depending on amp2 mode)
        numberOfAverages = uint16(5)    % Number of epochs (steps)
    end

    properties (Hidden)
        ampType
    end

    methods

        % ---- Timing --------------------------------------------------------

        function p = periodMs(obj)
            p = 1000 / obj.stepFrequency;
        end

        function t = get.tailTime(obj)
            t = obj.periodMs() - obj.preTime - obj.stimTime;
        end

        function set.stepFrequency(obj, f)
            if ~isscalar(f) || ~isfinite(f) || f <= 0
                warning('CfPatchStepHz:badFrequency', 'stepFrequency must be a positive finite scalar (Hz); ignoring %g.', f);
                return;
            end
            obj.stepFrequency = double(f);
            obj.warnIfTimingInvalid();
        end

        function set.preTime(obj, t)
            obj.preTime = double(t);
            obj.warnIfTimingInvalid();
        end

        function set.stimTime(obj, t)
            obj.stimTime = double(t);
            obj.warnIfTimingInvalid();
        end

        function [ok, msg] = timingIsValid(obj)
            % Valid when the tail is at least one sample long.
            minTailMs = 1e3 / obj.sampleRate;
            ok = obj.tailTime >= minTailMs;
            if ok
                msg = '';
            else
                msg = sprintf(['preTime (%g ms) + stimTime (%g ms) = %g ms exceeds the %g Hz step period of %g ms ' ...
                    '(tailTime would be %g ms). Reduce preTime/stimTime to at most %g ms total, or lower stepFrequency to at most %.4g Hz.'], ...
                    obj.preTime, obj.stimTime, obj.preTime + obj.stimTime, obj.stepFrequency, obj.periodMs(), ...
                    obj.tailTime, obj.periodMs() - minTailMs, 1000 / (obj.preTime + obj.stimTime + minTailMs));
            end
        end

        function validateTiming(obj)
            [ok, msg] = obj.timingIsValid();
            if ~ok
                error('CfPatchStepHz:timingInvalid', '%s', msg);
            end
        end

        function warnIfTimingInvalid(obj)
            if isempty(obj.stepFrequency) || isempty(obj.preTime) || isempty(obj.stimTime)
                return;
            end
            [ok, msg] = obj.timingIsValid();
            if ~ok
                warning('CfPatchStepHz:timingInvalid', '%s', msg);
            end
        end

        % ---- Rig / UI ----------------------------------------------------

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.FortenbachLabProtocol(obj, name);

            switch name
                case 'stepFrequency'
                    d.category = 'Stimulus';
                    d.displayName = sprintf('Step Frequency (Hz, period %.4g ms)', obj.periodMs());
                case 'preTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Pre Time (ms)';
                case 'stimTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Stim Time (ms)';
                case 'tailTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Tail Time (ms, auto)';
                case 'pulseAmplitude'
                    d.category = 'Stimulus';
                    d.displayName = 'Pulse Amplitude (mV)';
                case 'amp'
                    d.category = 'Amplifier';
                case 'amp2'
                    d.category = 'Amplifier';
                case 'amp2PulseAmplitude'
                    d.category = 'Amplifier';
                    d.displayName = 'Amp2 Pulse Amplitude (mV)';
                case 'numberOfAverages'
                    d.category = 'Acquisition';
                    d.displayName = 'Number of Steps';
                case 'objective'
                    d.isHidden = true;
            end

            if strncmp(name, 'amp2', 4) && numel(obj.rig.getDeviceNames('Amp')) < 2
                d.isHidden = true;
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()obj.createAmpStimulus());
        end

        function prepareRun(obj)
            obj.validateTiming();   % refuse to run with an impossible timing

            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
                obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp));
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
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
        end

        % ---- Stimuli -------------------------------------------------------

        function [prePts, stimPts, tailPts] = epochPoints(obj)
            % Sample counts; the total is forced to exactly one period so
            % rounding of the three parts cannot change the step rate.
            obj.validateTiming();
            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            totalPts = timeToPts(obj.periodMs());
            prePts   = timeToPts(obj.preTime);
            stimPts  = timeToPts(obj.stimTime);
            tailPts  = totalPts - prePts - stimPts;
        end

        function stim = createAmpStimulus(obj)
            device = obj.rig.getDevice(obj.amp);
            bg = device.background.quantity;
            units = device.background.displayUnits;

            [prePts, stimPts, tailPts] = obj.epochPoints();

            data = ones(1, prePts + stimPts + tailPts) * bg;
            data(prePts+1 : prePts+stimPts) = bg + obj.pulseAmplitude;

            % Embed cell-health test pulse in pre-time (if enabled).
            if obj.cellHealthEnabled()
                data = obj.embedTestPulse(data, obj.amp);
            end

            stim = obj.createStimulusFromArray(data, units);
        end

        function stim = createAmp2Stimulus(obj)
            device = obj.rig.getDevice(obj.amp2);
            bg = device.background.quantity;
            units = device.background.displayUnits;

            [prePts, stimPts, tailPts] = obj.epochPoints();

            data = ones(1, prePts + stimPts + tailPts) * bg;
            data(prePts+1 : prePts+stimPts) = bg + obj.amp2PulseAmplitude;

            stim = obj.createStimulusFromArray(data, units);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpStimulus());
            epoch.addResponse(obj.rig.getDevice(obj.amp));
            epoch.addParameter('stepFrequency_Hz', obj.stepFrequency);
            epoch.addParameter('stepPeriod_ms', obj.periodMs());
            epoch.addParameter('tailTime', obj.tailTime);

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

            % Zero-length interval: epochs abut, so the step period is exact.
            device = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(device, device.background, 0, obj.sampleRate);
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
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

    end

end
