classdef CfPatchIVCurveHCN4 < fortenbachlab.protocols.FortenbachLabProtocol
    % HCN4 activation / I-V protocol modelled on Meng et al. 2011 (Mol Pharmacol 79:866-873,
    % doi:10.1124/mol.110.070227), HEK 293 whole-cell recordings.
    %
    % Each epoch, from the amplifier holding potential (Meng: -40 mV):
    %
    %   preTime   | hyperpolarizing test step | tail step (fixed, -90 mV) | tailTime
    %   (holding) | (pulseSignal)             | (tailStepSignal)          | (holding)
    %
    % The test step starts at firstPulseSignal and changes by incrementPerPulse on each
    % subsequent epoch (default -40, -50, ... -120 mV). The step to a fixed tail potential
    % immediately after every test step gives a constant driving force, so the instantaneous
    % tail amplitude tracks the open probability reached at the end of the test step.
    %
    % Step duration is interpolated linearly from stimTimeFirst (first, least negative step)
    % to stimTimeLast (last, most negative step). Meng et al. state 3-4 s steps in Methods
    % and 6-14 s for HCN4 in the Fig. 3 legend; which duration went with which voltage is
    % not stated, so longest-at-least-negative is an assumption. Set both values equal for
    % fixed-duration steps.
    %
    % Online measurements (per epoch, saved as epoch parameters, in pA):
    %   instantaneousCurrent_pA  - mean over measureWindow starting measureDelay after test-step onset
    %   steadyStateCurrent_pA    - mean over the last measureWindow of the test step
    %   timeDependentCurrent_pA  - steady-state minus instantaneous (Meng's HCN amplitude)
    %   tailCurrent_pA           - mean over measureWindow starting measureDelay after tail-step onset
    %
    % No leak subtraction is applied. Voltage clamp only. The holding potential is the
    % amplifier background (set with the Holding Potential module); it is not changed here.

    properties
        amp                             % Output amplifier
        preTime = 100                   % Leading duration at holding (ms)
        stimTimeFirst = 14000           % Duration of the first (least negative) test step (ms)
        stimTimeLast = 6000             % Duration of the last (most negative) test step (ms)
        tailStepSignal = -90            % Fixed tail-step potential (mV)
        tailStepTime = 1000             % Tail-step duration (ms)
        tailTime = 500                  % Trailing duration at holding (ms)
        firstPulseSignal = -40          % First test-step potential (mV)
        incrementPerPulse = -10         % Change in test-step potential per pulse (mV)
        pulsesInFamily = uint16(9)      % Number of test steps in family (-40 to -120 mV in -10 mV steps)
        expectedHolding = -40           % Holding potential the protocol assumes (mV); warns if amp background differs
        measureDelay = 5                % Delay after a step edge before measuring instantaneous current (ms)
        measureWindow = 10              % Averaging window for instantaneous / steady-state / tail current (ms)
        numberOfAverages = uint16(1)    % Number of families
        interpulseInterval = 5          % Duration at holding between epochs (s)
    end

    properties (Dependent, SetAccess = private)
        familyDuration                  % Duration of one family including interpulse intervals (s)
    end

    properties (Hidden)
        ampType
        hcnFigure
    end

    methods

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.FortenbachLabProtocol(obj, name);

            % No light is delivered by this protocol.
            if strcmp(name, 'objective')
                d.isHidden = true;
            end

            switch name
                case 'preTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Pre Time (ms)';
                case 'stimTimeFirst'
                    d.category = 'Stimulus';
                    d.displayName = 'Stim Time, First Step (ms)';
                case 'stimTimeLast'
                    d.category = 'Stimulus';
                    d.displayName = 'Stim Time, Last Step (ms)';
                case 'tailStepSignal'
                    d.category = 'Stimulus';
                    d.displayName = 'Tail Step Signal (mV)';
                case 'tailStepTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Tail Step Time (ms)';
                case 'tailTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Tail Time (ms)';
                case 'firstPulseSignal'
                    d.category = 'Stimulus';
                    d.displayName = 'First Pulse Signal (mV)';
                case 'incrementPerPulse'
                    d.category = 'Stimulus';
                    d.displayName = 'Increment Per Pulse (mV)';
                case 'pulsesInFamily'
                    d.category = 'Stimulus';
                    d.displayName = 'Pulses In Family';
                case 'expectedHolding'
                    d.category = 'Stimulus';
                    d.displayName = 'Expected Holding (mV)';
                case 'measureDelay'
                    d.category = 'Analysis';
                    d.displayName = 'Measure Delay (ms)';
                case 'measureWindow'
                    d.category = 'Analysis';
                    d.displayName = 'Measure Window (ms)';
                case 'amp'
                    d.category = 'Amplifier';
                case 'numberOfAverages'
                    d.category = 'Acquisition';
                    d.displayName = 'Number of Averages';
                case 'interpulseInterval'
                    d.category = 'Acquisition';
                    d.displayName = 'Interpulse Interval (s)';
                case 'familyDuration'
                    d.category = 'Acquisition';
                    d.displayName = 'Family Duration (s)';
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

            % Voltage clamp only: the step values are in mV.
            if ~strcmp(obj.detectClampMode(obj.amp), 'Vclamp')
                error('CfPatchIVCurveHCN4:notVClamp', ...
                    'CfPatchIVCurveHCN4 requires voltage clamp; the amplifier is not in VClamp mode.');
            end

            % Timing sanity checks.
            if obj.stimTimeFirst <= 0 || obj.stimTimeLast <= 0 || obj.tailStepTime <= 0
                error('CfPatchIVCurveHCN4:badTiming', 'Step durations must be positive.');
            end
            minStep = obj.measureDelay + 2 * obj.measureWindow;
            if min(obj.stimTimeFirst, obj.stimTimeLast) < minStep ...
                    || obj.tailStepTime < obj.measureDelay + obj.measureWindow
                error('CfPatchIVCurveHCN4:badTiming', ...
                    'Test step / tail step are too short for measureDelay + measureWindow.');
            end

            % The protocol does not set the holding potential; warn if it is not the expected one.
            bg = obj.rig.getDevice(obj.amp).background.quantity;
            if abs(bg - obj.expectedHolding) > 0.5
                warning('CfPatchIVCurveHCN4:holdingMismatch', ...
                    ['Amplifier holding is %g mV but expectedHolding is %g mV. ' ...
                     'Set the holding potential before running, or change expectedHolding.'], ...
                    bg, obj.expectedHolding);
            end

            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
            obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp), ...
                'groupBy', {'pulseSignal'});

            if obj.cellHealthEnabled()
                obj.showFigure('fortenbachlab.figures.CellHealthFigure', obj.rig.getDevice(obj.amp));
            else
                obj.warnCellHealthDisabled();
            end

            % I-V and tail-activation figure (mean +/- SE, updated after each epoch).
            obj.hcnFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.updateHcnFigure);
            f = obj.hcnFigure.getFigureHandle();
            set(f, 'Name', 'HCN4 IV / Activation');
            delete(findall(f, 'Type', 'axes'));  % Remove axes from prior run
            obj.hcnFigure.userData.axIv   = subplot(2, 1, 1, 'Parent', f);
            obj.hcnFigure.userData.axTail = subplot(2, 1, 2, 'Parent', f);
            obj.hcnFigure.userData.ss   = containers.Map('KeyType', 'double', 'ValueType', 'any');
            obj.hcnFigure.userData.td   = containers.Map('KeyType', 'double', 'ValueType', 'any');
            obj.hcnFigure.userData.tail = containers.Map('KeyType', 'double', 'ValueType', 'any');
        end

        function t = stimTimeFor(obj, pulseNum)
            % Test-step duration (ms) for the given 1-based pulse index.
            n = double(obj.pulsesInFamily);
            if n <= 1
                t = obj.stimTimeFirst;
            else
                t = obj.stimTimeFirst + (obj.stimTimeLast - obj.stimTimeFirst) * (double(pulseNum) - 1) / (n - 1);
            end
            t = round(t);
        end

        function [stim, pulseSignal, stimMs] = createAmpStimulus(obj, pulseNum)
            pulseSignal = obj.incrementPerPulse * (double(pulseNum) - 1) + obj.firstPulseSignal;
            stimMs = obj.stimTimeFor(pulseNum);

            device = obj.rig.getDevice(obj.amp);
            bg = device.background.quantity;
            units = device.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            prePts      = timeToPts(obj.preTime);
            stimPts     = timeToPts(stimMs);
            tailStepPts = timeToPts(obj.tailStepTime);
            tailPts     = timeToPts(obj.tailTime);

            data = ones(1, prePts + stimPts + tailStepPts + tailPts) * bg;
            data(prePts+1 : prePts+stimPts) = pulseSignal;
            data(prePts+stimPts+1 : prePts+stimPts+tailStepPts) = obj.tailStepSignal;

            % Embed cell-health test pulse in pre-time (if enabled).
            if obj.cellHealthEnabled()
                data = obj.embedTestPulse(data, obj.amp);
            end

            stim = obj.createStimulusFromArray(data, units);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            pulseNum = mod(obj.numEpochsPrepared - 1, obj.pulsesInFamily) + 1;
            [stim, pulseSignal, stimMs] = obj.createAmpStimulus(pulseNum);

            epoch.addParameter('pulseSignal', pulseSignal);
            epoch.addParameter('pulseDuration', stimMs);   % test-step duration for THIS epoch (ms)
            epoch.addStimulus(obj.rig.getDevice(obj.amp), stim);
            epoch.addResponse(obj.rig.getDevice(obj.amp));
        end

        function m = measureEpoch(obj, epoch)
            % Instantaneous, steady-state and tail currents for one epoch (pA).
            stimMs = epoch.parameters('pulseDuration');
            responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
            [q, ~] = responseData.getData();   % base SI (A)

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            prePts  = timeToPts(obj.preTime);
            stimPts = timeToPts(stimMs);
            dPts    = timeToPts(obj.measureDelay);
            wPts    = max(1, timeToPts(obj.measureWindow));

            instIdx = prePts + dPts + (1:wPts);
            ssIdx   = (prePts + stimPts - wPts + 1) : (prePts + stimPts);
            tailIdx = prePts + stimPts + dPts + (1:wPts);
            if tailIdx(end) > numel(q)
                error('CfPatchIVCurveHCN4:shortResponse', 'Response is shorter than expected.');
            end

            m = struct();
            m.instantaneous = mean(q(instIdx)) * 1e12;
            m.steadyState   = mean(q(ssIdx)) * 1e12;
            m.timeDependent = m.steadyState - m.instantaneous;
            m.tail          = mean(q(tailIdx)) * 1e12;
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

            try
                m = obj.measureEpoch(epoch);
                epoch.addParameter('instantaneousCurrent_pA', m.instantaneous);
                epoch.addParameter('steadyStateCurrent_pA', m.steadyState);
                epoch.addParameter('timeDependentCurrent_pA', m.timeDependent);
                epoch.addParameter('tailCurrent_pA', m.tail);
            catch
            end
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);

            device = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(device, device.background, obj.interpulseInterval, obj.sampleRate);
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function updateHcnFigure(obj, figureHandler, epoch)
            % Called after each epoch. Accumulates the per-epoch measurements by test-step
            % potential and plots (top) the I-V and (bottom) the tail-current activation curve.
            try
                pulseSignal = epoch.parameters('pulseSignal');
                m = obj.measureEpoch(epoch);

                ud = figureHandler.userData;
                obj.accumulate(ud.ss, pulseSignal, m.steadyState);
                obj.accumulate(ud.td, pulseSignal, m.timeDependent);
                obj.accumulate(ud.tail, pulseSignal, m.tail);

                % --- Top: I-V -------------------------------------------------
                ax = ud.axIv;
                cla(ax);
                hold(ax, 'on');
                [v, mu, se] = obj.summarize(ud.ss);
                errorbar(ax, v, mu, se, 'o-', 'Color', 'k', 'MarkerFaceColor', 'k', ...
                    'MarkerSize', 5, 'LineWidth', 1.25, 'CapSize', 6, ...
                    'DisplayName', 'Steady state (end of step)');
                [v, mu, se] = obj.summarize(ud.td);
                errorbar(ax, v, mu, se, 's-', 'Color', [0.5 0.5 0.5], 'MarkerFaceColor', 'w', ...
                    'MarkerSize', 5, 'LineWidth', 1.25, 'CapSize', 6, ...
                    'DisplayName', 'Time-dependent (end - instantaneous)');
                xl = get(ax, 'XLim');
                line(ax, xl, [0 0], 'Color', [0.7 0.7 0.7], 'LineStyle', '--', 'HandleVisibility', 'off');
                legend(ax, 'show', 'Location', 'southeast', 'Box', 'off');
                xlabel(ax, 'Test potential (mV)');
                ylabel(ax, 'Current (pA)');
                title(ax, 'HCN4 I-V');
                set(ax, 'Box', 'off', 'TickDir', 'out');

                % --- Bottom: tail-current activation curve -----------------------
                ax = ud.axTail;
                cla(ax);
                hold(ax, 'on');
                [v, mu, se] = obj.summarize(ud.tail);
                errorbar(ax, v, mu, se, 'o', 'Color', 'k', 'MarkerFaceColor', 'k', ...
                    'MarkerSize', 5, 'LineWidth', 1.25, 'CapSize', 6);
                ttl = sprintf('Tail current at %g mV', obj.tailStepSignal);
                if numel(v) >= 5
                    try
                        % I = Ib + (Ia - Ib) / (1 + exp((V - Vh) / k)); Ia = fully activated.
                        boltz = @(p, x) p(2) + (p(1) - p(2)) ./ (1 + exp((x - p(3)) ./ p(4)));
                        p0 = [mu(1), mu(end), mean(v), 10];   % v is sorted ascending: mu(1) is most negative
                        p = fminsearch(@(p) sum((boltz(p, v) - mu).^2), p0);
                        vFit = linspace(min(v), max(v), 100);
                        plot(ax, vFit, boltz(p, vFit), '-', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.25);
                        ttl = sprintf('%s:  V_{1/2} = %.1f mV, k = %.1f mV (online fit)', ttl, p(3), abs(p(4)));
                    catch
                    end
                end
                xlabel(ax, 'Preceding test potential (mV)');
                ylabel(ax, 'Tail current (pA)');
                title(ax, ttl);
                set(ax, 'Box', 'off', 'TickDir', 'out');
            catch
                % Silently skip if data isn't available yet.
            end
        end

        function accumulate(~, map, key, val)
            % Append val to the array stored under key (containers.Map is a handle).
            if map.isKey(key)
                map(key) = [map(key), val];
            else
                map(key) = val;
            end
        end

        function [v, mu, se] = summarize(~, map)
            % Sorted keys with mean and SEM of the values stored under each.
            v = sort(cell2mat(map.keys));
            mu = zeros(size(v));
            se = zeros(size(v));
            for i = 1:numel(v)
                vals = map(v(i));
                mu(i) = mean(vals);
                if numel(vals) > 1
                    se(i) = std(vals) / sqrt(numel(vals));
                end
            end
        end

        function s = get.familyDuration(obj)
            n = double(obj.pulsesInFamily);
            stimTotal = 0;
            for i = 1:n
                stimTotal = stimTotal + obj.stimTimeFor(i);
            end
            s = (n * (obj.preTime + obj.tailStepTime + obj.tailTime) + stimTotal) / 1e3 ...
                + n * obj.interpulseInterval;
        end

    end

end
