classdef CfPatchIvCurveFlashTrainAdaptive < fortenbachlab.protocols.CfPatchIvCurveFlashTrain
    % Closed-loop version of CfPatchIvCurveFlashTrain: flashes are delivered
    % at a holding potential only once the step current has settled.
    %
    % Sequence at each holding potential V (staircase, single pass):
    %   1. PROBE segment(s), no flashes. The first probe contains the step
    %      from the previous level to V (preTime at the previous level, then
    %      probeDuration at V). At the end of each probe the two successive
    %      settleBlock (10 ms) blocks at the end of the segment are compared:
    %      settled if they differ by less than the threshold. Not settled ->
    %      another probe (entirely at V, the level is held throughout) up to
    %      maxProbesPerStep, after which flashes proceed anyway (forced).
    %   2. KINETICS segment: one flash at V followed by kineticsWindow of
    %      recording. Recovery time = first moment after flash offset at which
    %      |I - pre-flash baseline| stays below the threshold for
    %      recoveryHoldTime. The inter-flash interval for this step is then
    %      max(entered interFlashInterval, recoveryMarginFactor x recovery
    %      time). If the current has not recovered within kineticsWindow, the
    %      interval is set to recoveryMarginFactor x kineticsWindow (flagged).
    %   3. FLASH segment: the standard flash-train epoch at V (no step: the
    %      pre-time is already at V), 200 ms baseline, train, 200 ms
    %      baseline. Recovery check: the evaluationWindow before each flash
    %      after the first must be within the threshold of the pre-first-flash
    %      baseline. Not recovered -> inter-flash interval += k x adaptIncrement
    %      (k = attempt number) and the flash segment is repeated at V, up to
    %      maxAttemptsPerStep (then accepted, forced). Accepted -> next V, with
    %      the added inter-flash time halved.
    %
    % Threshold = max(adaptTolerance x step-evoked current, minAbsoluteChange).
    % Step-evoked current = current at the end of the probe minus the
    % pre-step baseline (last 20 ms before the step) measured on the first
    % probe of the step.
    %
    % Timing granularity: a settle decision can only take effect after the
    % DAQ output lead (~0.5-0.75 s) plus the segment in progress, so the time
    % from "settled" to the first flash is roughly lead + 200 ms baseline.
    % The amplifier is held at V by its background between segments.
    %
    % Entered properties are never modified (the next Record starts from the
    % entered values). Only flash segments that are accepted enter the raw,
    % flash-averaged and IV figures; every segment is recorded with
    % adaptivePhase ('probe'/'flash'), adaptiveAccepted and the measurements.

    properties
        probeDuration = 500             % Length of each settling probe at V (ms); first probe adds preTime for the step
        maxProbesPerStep = uint16(10)   % Flash anyway after this many probes
        adaptTolerance = 0.10           % Fraction of the step-evoked current allowed
        minAbsoluteChange = 50          % A change smaller than this always passes (pA)
        settleBlock = 10                % Settling test: two successive blocks of this length at the end of a probe (ms)
        evaluationWindow = 50           % Recovery window examined before flashes 2..n (ms)
        kineticsWindow = 2000           % Recording after the single kinetics flash (ms)
        recoveryHoldTime = 50           % Current must stay within threshold this long to count as recovered (ms)
        recoveryMarginFactor = 1.5      % Inter-flash interval = this x measured recovery time (never below the entered interval)
        adaptIncrement = 100            % Base time added to the inter-flash interval on recovery failure (ms); attempt k adds k x this
        maxAttemptsPerStep = uint16(5)  % Accept the flash segment after this many attempts
    end

    properties (Dependent, SetAccess = private)
        currentInterFlashInterval       % Inter-flash interval in use (ms, auto)
    end

    properties (Hidden)
        interFlashExtraMs = 0           % Adaptive time added to the inter-flash interval (run-scoped)
        phase = 'probe'                 % 'probe', 'kinetics' or 'flash'
        stepRecoveryTimeMs = NaN        % Recovery time measured at this step (ms after flash offset)
        stepIndex = 1                   % Current step (1-based)
        probeCount = 0                  % Probes run so far at this step
        attemptIndex = 1                % Flash-segment attempt at this step
        acceptedCount = 0               % Accepted steps so far
        stepPreBaselineA = NaN          % Pre-step baseline (A) from the first probe of this step
        lastDecision = struct()         % Evaluation result of the most recent segment
        rejectedFigure                  % Most recent failed segment with its evaluation windows
    end

    methods

        % ---- Timing overrides --------------------------------------------

        function t = interFlashIntervalMs(obj)
            t = obj.interFlashInterval + obj.interFlashExtraMs;
        end

        function t = effectiveStimTimeMs(obj)
            t = max(obj.stimTime, obj.minimumStimTime);   % stimTime property untouched
        end

        function t = get.currentInterFlashInterval(obj)
            t = obj.interFlashIntervalMs();
        end

        function n = currentPulseNum(obj)
            n = obj.stepIndex;
        end

        function V = currentStepSignal(obj)
            V = obj.firstPulseSignal + obj.incrementPerPulse * (obj.stepIndex - 1);
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.CfPatchIvCurveFlashTrain(obj, name);
            switch name
                case 'probeDuration'
                    d.category = 'Adaptive';
                    d.displayName = 'Probe Duration (ms)';
                case 'maxProbesPerStep'
                    d.category = 'Adaptive';
                    d.displayName = 'Max Probes per Step';
                case 'adaptTolerance'
                    d.category = 'Adaptive';
                    d.displayName = 'Tolerance (fraction of step current)';
                case 'minAbsoluteChange'
                    d.category = 'Adaptive';
                    d.displayName = 'Min Absolute Change to Fail (pA)';
                case 'settleBlock'
                    d.category = 'Adaptive';
                    d.displayName = 'Settling Block Length (ms, two successive blocks)';
                case 'evaluationWindow'
                    d.category = 'Adaptive';
                    d.displayName = 'Recovery Window before flashes 2..n (ms)';
                case 'kineticsWindow'
                    d.category = 'Adaptive';
                    d.displayName = 'Kinetics Flash: Recording Window (ms)';
                case 'recoveryHoldTime'
                    d.category = 'Adaptive';
                    d.displayName = 'Recovered = within threshold for (ms)';
                case 'recoveryMarginFactor'
                    d.category = 'Adaptive';
                    d.displayName = 'Inter-Flash Interval = factor x recovery time';
                case 'adaptIncrement'
                    d.category = 'Adaptive';
                    d.displayName = 'Base Time Added on Recovery Failure (ms, x attempt #)';
                case 'maxAttemptsPerStep'
                    d.category = 'Adaptive';
                    d.displayName = 'Max Flash Attempts per Step';
                case 'currentInterFlashInterval'
                    d.category = 'Adaptive';
                    d.displayName = 'Inter-Flash Interval in Use (ms, auto)';
                case 'numberOfAverages'
                    d.isHidden = true;   % single pass through the voltage sequence
            end
        end

        function prepareRun(obj)
            obj.interFlashExtraMs = 0;
            obj.phase = 'probe';
            obj.stepIndex = 1;
            obj.probeCount = 0;
            obj.attemptIndex = 1;
            obj.acceptedCount = 0;
            obj.stepPreBaselineA = NaN;
            obj.stepRecoveryTimeMs = NaN;
            obj.lastDecision = struct();
            obj.numberOfAverages = uint16(1);
            prepareRun@fortenbachlab.protocols.CfPatchIvCurveFlashTrain(obj);

            obj.rejectedFigure = obj.showFigure('fortenbachlab.figures.RejectedStepFigure', @obj.updateRejectedFigure);
            f = obj.rejectedFigure.getFigureHandle();
            set(f, 'Name', 'Adaptive Diagnostics (kinetics / last failed segment)');
            delete(findall(f, 'Type', 'axes'));
            delete(findall(f, 'Type', 'legend'));
            obj.rejectedFigure.userData.ax = axes('Parent', f);
            xlabel(obj.rejectedFigure.userData.ax, 'Time from segment start (ms)');
            ylabel(obj.rejectedFigure.userData.ax, 'Current (pA)');
            title(obj.rejectedFigure.userData.ax, 'Last Failed Segment (none yet)');
            hold(obj.rejectedFigure.userData.ax, 'on');
            grid(obj.rejectedFigure.userData.ax, 'on');
        end

        % ---- Epoch lifecycle: one segment in flight ----------------------

        function tf = shouldContinuePreloadingEpochs(obj)
            tf = (obj.numEpochsPrepared - obj.numEpochsCompleted) < 1 && obj.shouldContinuePreparingEpochs();
        end

        function tf = shouldWaitToContinuePreparingEpochs(obj)
            tf = (obj.numEpochsPrepared - obj.numEpochsCompleted) >= 1;
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.acceptedCount < double(obj.pulsesInFamily);
        end

        function tf = shouldContinueRun(obj)
            tf = obj.acceptedCount < double(obj.pulsesInFamily);
        end

        function prepareEpoch(obj, epoch)
            if strcmp(obj.phase, 'probe')
                % Base bookkeeping only (counters, telegraph parameters), then
                % build the probe segment here.
                obj.skipStandardEpochBuild = true;
                try
                    prepareEpoch@fortenbachlab.protocols.CfPatchIvCurveFlashTrain(obj, epoch);
                catch ex
                    obj.skipStandardEpochBuild = false;
                    rethrow(ex);
                end
                obj.skipStandardEpochBuild = false;
                obj.prepareProbeEpoch(epoch);
            elseif strcmp(obj.phase, 'kinetics')
                obj.skipStandardEpochBuild = true;
                try
                    prepareEpoch@fortenbachlab.protocols.CfPatchIvCurveFlashTrain(obj, epoch);
                catch ex
                    obj.skipStandardEpochBuild = false;
                    rethrow(ex);
                end
                obj.skipStandardEpochBuild = false;
                obj.prepareKineticsEpoch(epoch);
            else
                prepareEpoch@fortenbachlab.protocols.CfPatchIvCurveFlashTrain(obj, epoch);   % flash train at V (no step)
                epoch.addParameter('adaptivePhase', 'flash');
                epoch.addParameter('adaptiveAttempt', double(obj.attemptIndex));
                epoch.addParameter('adaptiveInterFlashExtra_ms', obj.interFlashExtraMs);
            end
            epoch.addParameter('adaptiveStepIndex', obj.stepIndex);
        end

        function prepareProbeEpoch(obj, epoch)
            V = obj.currentStepSignal();
            device = obj.rig.getDevice(obj.amp);
            units = device.background.displayUnits;
            if isempty(obj.currentLevel)
                preLevel = device.background.quantity;
            else
                preLevel = obj.currentLevel;
            end
            isFirst = obj.probeCount == 0;

            toPts = @(ms) round(ms / 1e3 * obj.sampleRate);
            probePts = toPts(obj.probeDuration);
            if isFirst
                prePts = toPts(obj.preTime);          % includes the step transition
            else
                prePts = 0;                            % already at V
            end
            data = ones(1, prePts + probePts) * V;
            data(1:prePts) = preLevel;
            epoch.addStimulus(device, obj.createStimulusFromArray(data, units));
            epoch.addResponse(device);
            obj.advanceHoldingLevel(V);                % hold V after this segment

            % LED at background, same length.
            ledDevice = obj.rig.getDevice(obj.led);
            epoch.addStimulus(ledDevice, obj.createStimulusFromArray( ...
                ones(1, prePts + probePts) * obj.lightBackground, ledDevice.background.displayUnits));

            epoch.addParameter('pulseSignal', V);
            epoch.addParameter('preStepLevel', preLevel);
            epoch.addParameter('adaptivePhase', 'probe');
            epoch.addParameter('adaptiveProbeIndex', obj.probeCount + 1);
            epoch.addParameter('probePreTime_ms', prePts / obj.sampleRate * 1e3);
            epoch.addParameter('probeDuration_ms', obj.probeDuration);
            epoch.addParameter('ndf', obj.ndf);
            epoch.addParameter('lightBackground', obj.lightBackground);

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function prepareKineticsEpoch(obj, epoch)
            % Single flash at V: PRE_FLASH_BASELINE_MS baseline, flash, kineticsWindow.
            V = obj.currentStepSignal();
            device = obj.rig.getDevice(obj.amp);
            toPts = @(ms) round(ms / 1e3 * obj.sampleRate);
            basePts  = toPts(obj.PRE_FLASH_BASELINE_MS);
            flashPts = toPts(obj.flashTime);
            postPts  = toPts(obj.kineticsWindow);
            n = basePts + flashPts + postPts;

            epoch.addStimulus(device, obj.createStimulusFromArray(ones(1, n) * V, device.background.displayUnits));
            epoch.addResponse(device);
            obj.advanceHoldingLevel(V);

            ledDevice = obj.rig.getDevice(obj.led);
            led = ones(1, n) * obj.lightBackground;
            led(basePts + 1 : basePts + flashPts) = obj.lightBackground + obj.flashAmplitude;
            epoch.addStimulus(ledDevice, obj.createStimulusFromArray(led, ledDevice.background.displayUnits));

            epoch.addParameter('pulseSignal', V);
            epoch.addParameter('adaptivePhase', 'kinetics');
            epoch.addParameter('flashAmplitude', obj.flashAmplitude);
            epoch.addParameter('flashTime', obj.flashTime);
            epoch.addParameter('kineticsFlashOnset_ms', obj.PRE_FLASH_BASELINE_MS);
            epoch.addParameter('kineticsWindow_ms', obj.kineticsWindow);
            epoch.addParameter('ndf', obj.ndf);
            epoch.addParameter('lightBackground', obj.lightBackground);
            epoch.addParameter('photonFluxFlash', obj.getPhotonFlux(obj.lightBackground + obj.flashAmplitude, obj.ndf));

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function completeEpoch(obj, epoch)
            p = epoch.parameters;
            phaseName = '';
            if p.isKey('adaptivePhase'), phaseName = char(p('adaptivePhase')); end
            isProbe = strcmp(phaseName, 'probe');
            isKinetics = strcmp(phaseName, 'kinetics');
            V = p('pulseSignal');

            if isProbe
                r = obj.evaluateProbe(epoch);
                obj.lastDecision = r;
                epoch.addParameter('adaptiveAccepted', false);            % probes never enter the summary figures
                epoch.addParameter('adaptiveSettled', r.settled);
                epoch.addParameter('adaptiveSettleChange_pA', r.settleChange_pA);
                epoch.addParameter('adaptiveThreshold_pA', r.threshold_pA);
                epoch.addParameter('adaptiveReferenceCurrent_pA', r.reference_pA);

                completeEpoch@fortenbachlab.protocols.CfPatchIvCurveFlashTrain(obj, epoch);   % counters + figures (gated)

                obj.probeCount = obj.probeCount + 1;
                if r.settled
                    fprintf('Adaptive IV: %+g mV settled after %d probe(s) (%.1f pA between blocks, thr %.1f pA); measuring flash kinetics.\n', ...
                        V, obj.probeCount, abs(r.settleChange_pA), r.threshold_pA);
                    obj.phase = 'kinetics';
                elseif obj.probeCount >= double(obj.maxProbesPerStep)
                    fprintf('Adaptive IV: %+g mV NOT settled after %d probes (%.1f pA between blocks, thr %.1f pA); measuring flash kinetics anyway.\n', ...
                        V, obj.probeCount, abs(r.settleChange_pA), r.threshold_pA);
                    obj.phase = 'kinetics';
                else
                    fprintf('Adaptive IV: %+g mV not settled (%.1f pA between blocks, thr %.1f pA); waiting another %g ms (probe %d).\n', ...
                        V, abs(r.settleChange_pA), r.threshold_pA, obj.probeDuration, obj.probeCount + 1);
                end
                return;
            end

            if isKinetics
                r = obj.evaluateKinetics(epoch);
                obj.lastDecision = r;
                epoch.addParameter('adaptiveAccepted', false);            % not part of the train average
                epoch.addParameter('adaptiveRecoveryTime_ms', r.recoveryTime_ms);
                epoch.addParameter('adaptiveKineticsInterval_ms', r.interval_ms);
                epoch.addParameter('adaptiveThreshold_pA', r.threshold_pA);
                epoch.addParameter('adaptiveReferenceCurrent_pA', r.reference_pA);
                epoch.addParameter('adaptiveKineticsPeak_pA', r.peak_pA);

                completeEpoch@fortenbachlab.protocols.CfPatchIvCurveFlashTrain(obj, epoch);

                obj.stepRecoveryTimeMs = r.recoveryTime_ms;
                obj.interFlashExtraMs = max(0, r.interval_ms - obj.interFlashInterval);
                if isnan(r.recoveryTime_ms)
                    fprintf('Adaptive IV: %+g mV flash NOT recovered within %g ms (peak %.1f pA, thr %.1f pA); inter-flash interval -> %g ms.\n', ...
                        V, obj.kineticsWindow, r.peak_pA, r.threshold_pA, obj.interFlashIntervalMs());
                else
                    fprintf('Adaptive IV: %+g mV flash recovered %.0f ms after offset (peak %.1f pA, thr %.1f pA); inter-flash interval -> %g ms.\n', ...
                        V, r.recoveryTime_ms, r.peak_pA, r.threshold_pA, obj.interFlashIntervalMs());
                end
                obj.phase = 'flash';
                return;
            end

            % ---- flash segment ----
            r = struct('recovered', true, 'forced', false, 'recoveryMax_pA', NaN, 'threshold_pA', NaN, 'reference_pA', NaN);
            try
                r = obj.evaluateFlashSegment(epoch);
            catch ex
                fprintf(2, 'CfPatchIvCurveFlashTrainAdaptive: evaluation failed (%s); accepting step.\n', ex.message);
            end
            accepted = r.recovered;
            if ~accepted && obj.attemptIndex >= double(obj.maxAttemptsPerStep)
                accepted = true;
                r.forced = true;
            end
            obj.lastDecision = r;
            epoch.addParameter('adaptiveAccepted', accepted);
            epoch.addParameter('adaptiveForced', r.forced);
            epoch.addParameter('adaptiveRecovered', r.recovered);
            epoch.addParameter('adaptiveRecoveryMax_pA', r.recoveryMax_pA);
            epoch.addParameter('adaptiveThreshold_pA', r.threshold_pA);
            epoch.addParameter('adaptiveReferenceCurrent_pA', r.reference_pA);
            epoch.addParameter('adaptiveProbesUsed', obj.probeCount);
            epoch.addParameter('adaptiveRecoveryTime_ms', obj.stepRecoveryTimeMs);

            completeEpoch@fortenbachlab.protocols.CfPatchIvCurveFlashTrain(obj, epoch);   % amplitudes, counters, figures

            if accepted
                if r.forced
                    fprintf('Adaptive IV: %+g mV accepted after %d flash attempts (limit reached; max %.1f pA off baseline).\n', ...
                        V, obj.attemptIndex, r.recoveryMax_pA);
                else
                    fprintf('Adaptive IV: %+g mV accepted (flash attempt %d).\n', V, obj.attemptIndex);
                end
                obj.acceptedCount = obj.acceptedCount + 1;
                obj.stepIndex = obj.stepIndex + 1;
                obj.phase = 'probe';
                obj.probeCount = 0;
                obj.attemptIndex = 1;
                obj.stepPreBaselineA = NaN;
                obj.stepRecoveryTimeMs = NaN;
                obj.interFlashExtraMs = 0;   % next step measures its own kinetics
            else
                added = double(obj.attemptIndex) * obj.adaptIncrement;
                obj.interFlashExtraMs = obj.interFlashExtraMs + added;
                obj.attemptIndex = obj.attemptIndex + 1;
                fprintf('Adaptive IV: %+g mV not recovered between flashes (max %.1f pA off baseline, thr %.1f pA); +%g ms -> inter-flash interval %g ms, repeating flashes (attempt %d).\n', ...
                    V, r.recoveryMax_pA, r.threshold_pA, added, obj.interFlashIntervalMs(), obj.attemptIndex);
            end
        end

        function tf = epochContributes(~, epoch)
            tf = false;
            try
                p = epoch.parameters;
                tf = p.isKey('adaptiveAccepted') && logical(p('adaptiveAccepted'));
            catch
            end
        end

        % ---- Evaluation ----------------------------------------------------

        function thr = thresholdA(obj, refA)
            thr = max(obj.adaptTolerance * abs(refA), obj.minAbsoluteChange * 1e-12);
        end

        function r = evaluateProbe(obj, epoch)
            % Two successive settleBlock-ms blocks at the end of the probe.
            q = obj.epochResponseData(epoch);
            p = epoch.parameters;
            sr = obj.sampleRate;
            toPts = @(ms) round(ms / 1e3 * sr);
            prePts = 0;
            if p.isKey('probePreTime_ms'), prePts = toPts(p('probePreTime_ms')); end

            if prePts > 0   % first probe of the step: capture the pre-step baseline
                blPts = min(prePts, toPts(20));
                obj.stepPreBaselineA = mean(q(prePts - blPts + 1 : prePts));
            end

            blk = max(1, toPts(obj.settleBlock));
            n = numel(q);
            blockLate  = mean(q(n - blk + 1 : n));
            blockEarly = mean(q(n - 2*blk + 1 : n - blk));
            if isnan(obj.stepPreBaselineA)
                refA = 0;
            else
                refA = blockLate - obj.stepPreBaselineA;
            end
            thr = obj.thresholdA(refA);
            change = blockLate - blockEarly;
            r = struct('kind', 'probe', 'settled', abs(change) < thr, ...
                       'settleChange_pA', change * 1e12, 'threshold_pA', thr * 1e12, 'reference_pA', refA * 1e12, ...
                       'blockEarly_pA', blockEarly * 1e12, 'blockLate_pA', blockLate * 1e12);
        end

        function r = evaluateKinetics(obj, epoch)
            % Time after flash offset for |I - baseline| to stay within the
            % threshold for recoveryHoldTime; derived inter-flash interval.
            q = obj.epochResponseData(epoch);
            sr = obj.sampleRate;
            toPts = @(ms) round(ms / 1e3 * sr);
            onset = toPts(obj.PRE_FLASH_BASELINE_MS) + 1;
            off   = onset + toPts(obj.flashTime) - 1;
            winPts = toPts(obj.evaluationWindow);
            baseline = mean(q(max(1, onset - winPts) : onset - 1));
            if isnan(obj.stepPreBaselineA), refA = 0; else, refA = baseline - obj.stepPreBaselineA; end
            thr = obj.thresholdA(refA);

            post = q(off + 1 : end) - baseline;
            [~, ip] = max(abs(post));
            peakA = post(ip);
            within = abs(post) < thr;
            holdPts = max(1, toPts(obj.recoveryHoldTime));
            tRec = NaN;
            % First index from which `within` holds for holdPts consecutive samples.
            run = 0;
            for i = 1:numel(within)
                if within(i)
                    run = run + 1;
                    if run >= holdPts
                        tRec = (i - holdPts + 1) / sr * 1e3;   % ms after offset
                        break;
                    end
                else
                    run = 0;
                end
            end
            if isnan(tRec)
                interval = obj.recoveryMarginFactor * obj.kineticsWindow;
            else
                interval = obj.recoveryMarginFactor * tRec;
            end
            interval = max(interval, obj.interFlashInterval);
            r = struct('kind', 'kinetics', 'recoveryTime_ms', tRec, 'interval_ms', round(interval), ...
                       'threshold_pA', thr * 1e12, 'reference_pA', refA * 1e12, 'peak_pA', peakA * 1e12, ...
                       'baseline_pA', baseline * 1e12);
        end

        function r = evaluateFlashSegment(obj, epoch)
            % Recovery before flashes 2..n relative to the pre-first-flash baseline.
            q = obj.epochResponseData(epoch);
            sr = obj.sampleRate;
            toPts = @(ms) round(ms / 1e3 * sr);
            prePts = toPts(obj.preTime);
            winPts = toPts(obj.evaluationWindow);
            onsets = prePts + toPts(obj.flashOnsetsMs()) + 1;

            w1 = q(onsets(1) - winPts : onsets(1) - 1);
            baseline = mean(w1);
            if isnan(obj.stepPreBaselineA)
                refA = 0;
            else
                refA = baseline - obj.stepPreBaselineA;
            end
            thr = obj.thresholdA(refA);

            recMaxA = 0;
            for k = 2:numel(onsets)
                wk = q(onsets(k) - winPts : onsets(k) - 1);
                recMaxA = max(recMaxA, abs(mean(wk) - baseline));
            end
            r = struct('kind', 'flash', 'recovered', recMaxA < thr, 'forced', false, ...
                       'recoveryMax_pA', recMaxA * 1e12, 'threshold_pA', thr * 1e12, 'reference_pA', refA * 1e12, ...
                       'baseline_pA', baseline * 1e12);
        end

        % ---- Last failed segment figure -----------------------------------

        function updateRejectedFigure(obj, figureHandler, epoch)
            try
                p = epoch.parameters;
                r = obj.lastDecision;
                if ~isfield(r, 'kind'), return; end
                isProbe = strcmp(r.kind, 'probe');
                isKin = strcmp(r.kind, 'kinetics');
                if isProbe && r.settled, return; end
                if ~isProbe && ~isKin && r.recovered, return; end

                q = obj.epochResponseData(epoch) * 1e12;   % pA
                sr = obj.sampleRate;
                t = (0:numel(q)-1) / sr * 1e3;              % ms from segment start
                ax = figureHandler.userData.ax;
                cla(ax);
                set(ax, 'XLimMode', 'auto', 'YLimMode', 'auto');
                plot(ax, t, q, 'Color', [0.2 0.2 0.2], 'LineWidth', 1, 'HandleVisibility', 'off');
                yl = get(ax, 'YLim');
                shade = @(x0, x1, col, name) patch(ax, [x0 x1 x1 x0], [yl(1) yl(1) yl(2) yl(2)], col, ...
                    'EdgeColor', 'none', 'FaceAlpha', 0.3, 'DisplayName', name);
                badCol = [1 0.55 0.55];

                if isKin
                    onsetMs = obj.PRE_FLASH_BASELINE_MS;
                    flashMs = obj.flashTime;
                    shade(onsetMs, onsetMs + flashMs, [1 0.85 0.3], 'flash');
                    shade(onsetMs - obj.evaluationWindow, onsetMs, [0.75 0.75 0.95], 'pre-flash baseline window');
                    bl = r.baseline_pA;
                    line(ax, [t(1) t(end)], [bl bl], 'Color', [0 0.45 0.74], 'LineStyle', '--', 'DisplayName', 'baseline');
                    line(ax, [t(1) t(end)], [bl + r.threshold_pA, bl + r.threshold_pA], 'Color', [0 0.45 0.74], 'LineStyle', ':', 'DisplayName', '+/- threshold');
                    line(ax, [t(1) t(end)], [bl - r.threshold_pA, bl - r.threshold_pA], 'Color', [0 0.45 0.74], 'LineStyle', ':', 'HandleVisibility', 'off');
                    if ~isnan(r.recoveryTime_ms)
                        tr = onsetMs + flashMs + r.recoveryTime_ms;
                        line(ax, [tr tr], yl, 'Color', [0.2 0.6 0.2], 'LineWidth', 1.5, 'DisplayName', 'recovered');
                        ttl = sprintf('Kinetics at %+g mV: recovered %.0f ms after offset -> inter-flash %g ms', ...
                            p('pulseSignal'), r.recoveryTime_ms, r.interval_ms);
                    else
                        ttl = sprintf('Kinetics at %+g mV: NOT recovered within %g ms -> inter-flash %g ms', ...
                            p('pulseSignal'), obj.kineticsWindow, r.interval_ms);
                    end
                elseif isProbe
                    prePre = 0;
                    if p.isKey('probePreTime_ms'), prePre = p('probePreTime_ms'); end
                    if prePre > 0
                        shade(max(0, prePre - 20), prePre, [0.75 0.75 0.95], 'pre-step baseline');
                        line(ax, [prePre prePre], yl, 'Color', [0.5 0.5 0.5], 'LineStyle', ':', 'HandleVisibility', 'off');
                    end
                    B = obj.settleBlock; tEnd = t(end);
                    shade(tEnd - 2*B, tEnd - B, badCol, 'settling block 1');
                    h = shade(tEnd - B, tEnd, badCol, 'settling block 2'); set(h, 'FaceAlpha', 0.5);
                    line(ax, [tEnd-2*B tEnd-B], [r.blockEarly_pA r.blockEarly_pA], 'Color', 'k', 'LineWidth', 2, 'HandleVisibility', 'off');
                    line(ax, [tEnd-B tEnd], [r.blockLate_pA r.blockLate_pA], 'Color', 'k', 'LineWidth', 2, 'HandleVisibility', 'off');
                    ttl = sprintf('Probe %d at %+g mV — NOT SETTLED: %.1f pA between blocks (thr %.1f pA)', ...
                        double(p('adaptiveProbeIndex')), p('pulseSignal'), abs(r.settleChange_pA), r.threshold_pA);
                else
                    flashMs = obj.flashTime;
                    onsetsMs = obj.preTime + obj.flashOnsetsMs();
                    try
                        if p.isKey('flashOnsets_ms')
                            o = str2double(strsplit(strtrim(char(p('flashOnsets_ms'))), ','));
                            onsetsMs = obj.preTime + o(~isnan(o));
                        end
                        if p.isKey('flashTime'), flashMs = p('flashTime'); end
                    catch
                    end
                    for k = 1:numel(onsetsMs)
                        h = shade(onsetsMs(k), onsetsMs(k) + flashMs, [1 0.85 0.3], 'flash');
                        if k > 1, set(h, 'HandleVisibility', 'off'); end
                    end
                    for k = 2:numel(onsetsMs)
                        h = shade(onsetsMs(k) - obj.evaluationWindow, onsetsMs(k), badCol, 'recovery windows');
                        if k > 2, set(h, 'HandleVisibility', 'off'); end
                    end
                    bl = r.baseline_pA;
                    line(ax, [t(1) t(end)], [bl bl], 'Color', [0 0.45 0.74], 'LineStyle', '--', 'DisplayName', 'pre-flash baseline');
                    line(ax, [t(1) t(end)], [bl + r.threshold_pA, bl + r.threshold_pA], 'Color', [0 0.45 0.74], 'LineStyle', ':', 'DisplayName', '+/- threshold');
                    line(ax, [t(1) t(end)], [bl - r.threshold_pA, bl - r.threshold_pA], 'Color', [0 0.45 0.74], 'LineStyle', ':', 'HandleVisibility', 'off');
                    ttl = sprintf('Flash attempt %d at %+g mV — NOT RECOVERED: max %.1f pA off baseline (thr %.1f pA)', ...
                        double(p('adaptiveAttempt')), p('pulseSignal'), r.recoveryMax_pA, r.threshold_pA);
                end
                uistack(findobj(ax, 'Type', 'patch'), 'bottom');
                set(ax, 'XLimMode', 'auto', 'YLimMode', 'auto');
                legend(ax, 'show', 'Location', 'eastoutside');
                title(ax, ttl, 'Interpreter', 'none');
                xlabel(ax, 'Time from segment start (ms)');
                ylabel(ax, 'Current (pA)');
            catch
            end
        end

    end

end
