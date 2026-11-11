classdef CfPatchIvCurveFlashTrain < fortenbachlab.protocols.FortenbachLabProtocol
    % IV curve with a train of LED flashes delivered during each voltage step.
    %
    % Holding potentials ascend from firstPulseSignal in steps of
    % incrementPerPulse (positive only) for pulsesInFamily steps. The
    % sequence is run once: each holding potential is visited a single time
    % with its train of flashes. No cell-health test pulse is embedded.
    %
    % Staircase: the voltage never returns to the original holding potential
    % between steps. Each epoch's preTime is spent at the PREVIOUS level
    % (the original holding potential for the first step), the step to the
    % new level occurs at preTime, and the new level is held through
    % stimTime + tailTime and, via the amplifier background, through any gap
    % until the next epoch. The original holding potential is restored when
    % the run ends (or is stopped).
    %
    % Epoch layout (ms):
    %   preTime (previous level) | <------------ stimTime (new level) ------------>| tailTime (new level)
    %                               200 baseline | flash, gap, flash, ... flash | 200 baseline | (any extra)
    %
    % stimTime is raised automatically whenever the flash train plus the two
    % 200 ms baselines would not fit; it is never lowered automatically.
    %
    % Analysis (per flash): baseline = mean over [onset-15, onset-5] ms;
    % response = signed extremum of (data - baseline) over
    % [offset+5, offset+50] ms. Per-flash amplitudes are averaged within the
    % epoch, then plotted as mean +/- SE across repeats vs. holding potential.

    properties
        amp                             % Output amplifier
        led                             % Output LED
        firstPulseSignal = -80          % Starting holding potential (mV or pA depending on amp mode)
        incrementPerPulse = 10          % Step size, must be > 0 (mV or pA)
        pulsesInFamily = uint16(15)     % Number of steps (-80 to +60 mV in 10 mV steps)
        numberOfAverages = uint16(1)    % Fixed at 1: single pass through the voltage sequence (hidden)
        preTime = 50                    % Pre-step duration (ms)
        stimTime = 500                  % Step duration (ms); auto-raised to fit the flash train + baselines
        tailTime = 50                   % Post-step duration (ms)
        flashAmplitude = 10             % Flash intensity: LED voltage above background (V [0-10])
        flashTime = 50                  % Flash duration (ms)
        numberOfFlashes = uint16(5)     % Flashes per step
        interFlashInterval = 200        % Gap from flash offset to next flash onset (ms)
        lightBackground = 0             % LED background voltage (V)
        ndf = 0.0                       % ND filter setting
        amp2PulseSignal = -60           % Holding potential for secondary amp (mV or pA)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
        flashTrainDuration              % First flash onset to last flash offset (ms, auto)
        minimumStimTime                 % 200 + flashTrainDuration + 200 (ms, auto)
    end

    properties (Constant, Hidden)
        PRE_FLASH_BASELINE_MS  = 200    % Step onset to first flash onset
        POST_FLASH_BASELINE_MS = 200    % Last flash offset to end of required step time
        ANALYSIS_BL_START_MS   = 15     % Baseline window: onset-15 ms ...
        ANALYSIS_BL_END_MS     = 5      % ... to onset-5 ms
        ANALYSIS_RESP_START_MS = 5      % Response window: offset+5 ms ...
        ANALYSIS_RESP_END_MS   = 50     % ... to offset+50 ms
        AVG_PRE_MS             = 10     % Flash-average display window: onset-10 ms ...
        AVG_POST_MS            = 100    % ... to offset+100 ms (baseline = the 10 ms before onset)
    end

    properties (Hidden)
        ampType
        ledType
        ndfType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
        ivFigure
        originalHolding                 % Amp background at run start (quantity, display units) to restore at run end
        skipStandardEpochBuild = false  % When true, prepareEpoch does only base bookkeeping (for subclasses)
        currentLevel                    % Level (mV/pA) held going INTO the next epoch; [] = device background
        rawFigure                       % Raw current response, one trace per holding potential
        flashAvgFigure                  % Flash-averaged, baseline-zeroed response per holding potential
    end

    methods

        % ---- Derived timing ------------------------------------------------

        function d = get.flashTrainDuration(obj)
            n = double(obj.numberOfFlashes);
            d = n * obj.flashTime + max(n - 1, 0) * obj.interFlashIntervalMs();
        end

        function t = get.minimumStimTime(obj)
            t = obj.preFlashBaselineMs() + obj.flashTrainDuration + obj.POST_FLASH_BASELINE_MS;
        end

        function t = preFlashBaselineMs(obj)
            % Step onset to first flash onset (ms). Subclasses may override
            % to make this adaptive.
            t = obj.PRE_FLASH_BASELINE_MS;
        end

        function t = interFlashIntervalMs(obj)
            % Gap between flashes actually used (ms). Subclasses may override
            % to add adaptive time WITHOUT touching the user-entered property.
            t = obj.interFlashInterval;
        end

        function t = effectiveStimTimeMs(obj)
            % Step duration actually used (ms). Subclasses may override to
            % lengthen the step at run time without changing the property.
            t = obj.stimTime;
        end

        function onsets = flashOnsetsMs(obj)
            % Flash onsets measured from step onset (ms).
            n = double(obj.numberOfFlashes);
            onsets = obj.preFlashBaselineMs() + (0:n-1) * (obj.flashTime + obj.interFlashIntervalMs());
        end

        % ---- Setters: keep stimTime >= minimum, steps ascending ------------

        function set.stimTime(obj, t)
            obj.stimTime = double(t);
            obj.enforceMinimumStimTime();
        end

        function set.flashTime(obj, t)
            if ~isscalar(t) || ~isfinite(t) || t <= 0
                warning('CfPatchIvCurveFlashTrain:badValue', 'flashTime must be > 0 ms; ignoring %g.', t);
                return;
            end
            obj.flashTime = double(t);
            obj.enforceMinimumStimTime();
        end

        function set.numberOfFlashes(obj, n)
            if ~isscalar(n) || ~isfinite(double(n)) || n < 1
                warning('CfPatchIvCurveFlashTrain:badValue', 'numberOfFlashes must be >= 1; ignoring %g.', double(n));
                return;
            end
            obj.numberOfFlashes = uint16(n);
            obj.enforceMinimumStimTime();
        end

        function set.interFlashInterval(obj, t)
            if ~isscalar(t) || ~isfinite(t) || t < 0
                warning('CfPatchIvCurveFlashTrain:badValue', 'interFlashInterval must be >= 0 ms; ignoring %g.', t);
                return;
            end
            obj.interFlashInterval = double(t);
            obj.enforceMinimumStimTime();
        end

        function set.incrementPerPulse(obj, v)
            if ~isscalar(v) || ~isfinite(v) || v <= 0
                warning('CfPatchIvCurveFlashTrain:badIncrement', ...
                    'incrementPerPulse must be positive (holding potentials only ascend); ignoring %g.', v);
                return;
            end
            obj.incrementPerPulse = double(v);
        end

        function tf = cellHealthEnabled(~)
            % No embedded test pulse in this protocol.
            tf = false;
        end

        % ---- Rig / UI ------------------------------------------------------

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

            switch name
                case 'firstPulseSignal'
                    d.category = 'Voltage Steps';
                    d.displayName = 'Starting Voltage (mV)';
                case 'incrementPerPulse'
                    d.category = 'Voltage Steps';
                    d.displayName = 'Step Size (mV, > 0)';
                case 'pulsesInFamily'
                    d.category = 'Voltage Steps';
                    d.displayName = 'Number of Steps';
                case 'preTime'
                    d.category = 'Voltage Steps';
                    d.displayName = 'Pre-Step Duration (ms)';
                case 'stimTime'
                    d.category = 'Voltage Steps';
                    d.displayName = sprintf('Step Duration (ms, min %g)', obj.minimumStimTime);
                case 'tailTime'
                    d.category = 'Voltage Steps';
                    d.displayName = 'Post-Step Duration (ms)';
                case 'flashAmplitude'
                    d.category = 'Flashes';
                    d.displayName = 'Flash Intensity (V)';
                case 'flashTime'
                    d.category = 'Flashes';
                    d.displayName = 'Flash Duration (ms)';
                case 'numberOfFlashes'
                    d.category = 'Flashes';
                    d.displayName = 'Number of Flashes';
                case 'interFlashInterval'
                    d.category = 'Flashes';
                    d.displayName = 'Inter-Flash Interval (ms, offset to next onset)';
                case 'flashTrainDuration'
                    d.category = 'Flashes';
                    d.displayName = 'Flash Train Duration (ms, auto)';
                case 'minimumStimTime'
                    d.category = 'Flashes';
                    d.displayName = 'Required Step Duration (ms, auto)';
                case {'led', 'lightBackground', 'ndf'}
                    d.category = 'Light';
                    if strcmp(name, 'lightBackground'), d.displayName = 'Background Voltage (V)'; end
                    if strcmp(name, 'ndf')
                        d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0});
                    end
                case {'amp', 'amp2', 'amp2PulseSignal'}
                    d.category = 'Amplifier';
                case 'numberOfAverages'
                    d.isHidden = true;   % single pass
                case 'objective'
                    d.isHidden = true;
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()createPreviewStimuli(obj));
            function s = createPreviewStimuli(obj)
                s = cell(1, obj.pulsesInFamily + 1);
                for i = 1:obj.pulsesInFamily
                    s{i} = obj.createAmpStimulus(i);
                end
                s{end} = obj.createLedStimulus();
            end
        end

        function prepareRun(obj)
            obj.numberOfAverages = uint16(1);   % one pass; no family repeats
            obj.enforceMinimumStimTime();
            if obj.interFlashInterval < obj.ANALYSIS_RESP_END_MS
                warning('CfPatchIvCurveFlashTrain:windowOverlap', ...
                    'interFlashInterval (%g ms) is shorter than the %g ms response window; windows overlap the next flash.', ...
                    obj.interFlashInterval, obj.ANALYSIS_RESP_END_MS);
            end

            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Staircase bookkeeping: remember the holding potential to restore,
            % and start the first step from it.
            ampDevice = obj.rig.getDevice(obj.amp);
            bg = ampDevice.background;
            % Store as primitives in DISPLAY units (quantity + displayUnits) so
            % writing it back cannot be misread as volts (see Device.set.background).
            obj.originalHolding = symphonyui.core.Measurement(bg.quantity, bg.displayUnits);
            obj.currentLevel = bg.quantity;
            fprintf('%s: holding %g %s at run start; staircase from %g in steps of %g.\n', ...
                class(obj), bg.quantity, bg.displayUnits, obj.firstPulseSignal, obj.incrementPerPulse);

            % Raw current response: full epoch trace, one line per holding potential.
            obj.rawFigure = obj.newTraceFigure('fortenbachlab.figures.RawTraceFigure', ...
                'Raw Current Response', @obj.updateRawFigure, 'Time (s)', 'Current (pA)');

            % Flash-averaged response: mean over the step's flashes, baseline-zeroed,
            % one line per holding potential, overlaid.
            obj.flashAvgFigure = obj.newTraceFigure('fortenbachlab.figures.FlashAverageFigure', ...
                'Flash-Averaged Response', @obj.updateFlashAvgFigure, 'Time from flash onset (ms)', 'Current, baseline-zeroed (pA)');

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp2));
            end

            % Flash-response IV figure.
            obj.ivFigure = obj.showFigure('fortenbachlab.figures.IvCurveFigure', @obj.updateIvFigure);
            f = obj.ivFigure.getFigureHandle();
            set(f, 'Name', 'Flash Response IV');
            delete(findall(f, 'Type', 'axes'));
            obj.ivFigure.userData.ax = axes('Parent', f);
            xlabel(obj.ivFigure.userData.ax, 'Holding Potential (mV)');
            ylabel(obj.ivFigure.userData.ax, 'Flash Response (pA)');
            title(obj.ivFigure.userData.ax, 'Flash Response IV (mean +/- SE across flashes in the step)');
            hold(obj.ivFigure.userData.ax, 'on');
            grid(obj.ivFigure.userData.ax, 'on');
            obj.ivFigure.userData.ivData = containers.Map('KeyType', 'double', 'ValueType', 'any');

            % Filter wheel and LED background.
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
                warning('CfPatchIvCurveFlashTrain:setNDFFailed', ...
                    'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
            end
            obj.setLedBackground(obj.led, obj.lightBackground);
        end

        % ---- Stimuli -------------------------------------------------------

        function n = currentPulseNum(obj)
            % 1-based index of the step for the epoch being prepared.
            % Subclasses may override (e.g. to repeat a step).
            n = mod(obj.numEpochsPrepared - 1, obj.pulsesInFamily) + 1;
        end

        function [prePts, stimPts, tailPts] = epochPoints(obj)
            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            prePts  = timeToPts(obj.preTime);
            stimPts = timeToPts(obj.effectiveStimTimeMs());
            tailPts = timeToPts(obj.tailTime);
        end

        function [stim, pulseSignal] = createAmpStimulus(obj, pulseNum)
            pulseSignal = obj.firstPulseSignal + obj.incrementPerPulse * (double(pulseNum) - 1);

            device = obj.rig.getDevice(obj.amp);
            units = device.background.displayUnits;
            if isempty(obj.currentLevel)
                preLevel = device.background.quantity;   % preview / before run
            else
                preLevel = obj.currentLevel;
            end

            [prePts, stimPts, tailPts] = obj.epochPoints();
            data = ones(1, prePts + stimPts + tailPts) * pulseSignal;   % new level held through the tail
            data(1:prePts) = preLevel;                                   % previous level before the step
            % (no test pulse)

            stim = obj.createStimulusFromArray(data, units);
        end

        function advanceHoldingLevel(obj, newLevel)
            % Hold the amplifier at newLevel between epochs (Symphony outputs
            % the device background whenever no epoch is playing) and make it
            % the pre-step level of the next epoch. Must be called when the
            % epoch is QUEUED (prepareEpoch), not when it completes: output is
            % streamed ~0.5-0.75 s ahead of the hardware, so the background
            % for the gap after an epoch is pulled before the epoch finishes.
            try
                device = obj.rig.getDevice(obj.amp);
                units = device.background.displayUnits;
                device.background = symphonyui.core.Measurement(newLevel, units);
            catch e
                warning('CfPatchIvCurveFlashTrain:background', 'Could not update amp background: %s', e.message);
            end
            obj.currentLevel = newLevel;
        end

        function stim = createAmp2Stimulus(obj)
            device = obj.rig.getDevice(obj.amp2);
            units = device.background.displayUnits;

            [prePts, stimPts, tailPts] = obj.epochPoints();
            data = ones(1, prePts + stimPts + tailPts) * device.background.quantity;
            data(prePts+1 : prePts+stimPts) = obj.amp2PulseSignal;

            stim = obj.createStimulusFromArray(data, units);
        end

        function stim = createLedStimulus(obj)
            device = obj.rig.getDevice(obj.led);
            units = device.background.displayUnits;

            [prePts, stimPts, tailPts] = obj.epochPoints();
            totalPts = prePts + stimPts + tailPts;
            data = ones(1, totalPts) * obj.lightBackground;

            flashPts = round(obj.flashTime / 1e3 * obj.sampleRate);
            onsets = obj.flashOnsetsMs();
            for k = 1:numel(onsets)
                on  = prePts + round(onsets(k) / 1e3 * obj.sampleRate) + 1;
                off = min(on + flashPts - 1, prePts + stimPts);   % never beyond the step
                if on <= prePts + stimPts
                    data(on:off) = obj.lightBackground + obj.flashAmplitude;
                end
            end

            stim = obj.createStimulusFromArray(data, units);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
            if obj.skipStandardEpochBuild
                return;   % subclass builds its own epoch (e.g. adaptive probe segment)
            end

            if isempty(obj.currentLevel)
                preLevel = obj.rig.getDevice(obj.amp).background.quantity;
            else
                preLevel = obj.currentLevel;
            end
            [stim, pulseSignal] = obj.createAmpStimulus(obj.currentPulseNum());   % uses currentLevel as pre-level
            obj.advanceHoldingLevel(pulseSignal);                                   % hold the new level after this epoch

            epoch.addParameter('pulseSignal', pulseSignal);
            epoch.addParameter('preStepLevel', preLevel);
            epoch.addStimulus(obj.rig.getDevice(obj.amp), stim);
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
            epoch.addParameter('flashAmplitude', obj.flashAmplitude);
            epoch.addParameter('flashTime', obj.flashTime);
            epoch.addParameter('numberOfFlashes', double(obj.numberOfFlashes));
            epoch.addParameter('interFlashInterval', obj.interFlashIntervalMs());
            epoch.addParameter('firstFlashDelay', obj.preFlashBaselineMs());
            epoch.addParameter('flashOnsets_ms', sprintf('%g,', obj.flashOnsetsMs()));
            epoch.addParameter('stimTime', obj.effectiveStimTimeMs());
            epoch.addParameter('lightBackground', obj.lightBackground);
            epoch.addParameter('ndf', obj.ndf);
            epoch.addParameter('photonFluxFlash', obj.getPhotonFlux(obj.lightBackground + obj.flashAmplitude, obj.ndf));
            epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightBackground, obj.ndf));

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addStimulus(obj.rig.getDevice(obj.amp2), obj.createAmp2Stimulus());
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function completeEpoch(obj, epoch)
            % Save per-flash amplitudes and their mean with the epoch.
            try
                q = obj.epochResponseData(epoch);
                amps = obj.computeFlashAmplitudes(q);
                epoch.addParameter('flashResponses_A', sprintf('%.6e,', amps));
                epoch.addParameter('flashResponseMean_A', mean(amps));
            catch
            end

            completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);

            % Zero-length interval: steps abut.
            device = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(device, device.background, 0, obj.sampleRate);
            ledDevice = obj.rig.getDevice(obj.led);
            interval.addDirectCurrentStimulus(ledDevice, ledDevice.background, 0, obj.sampleRate);
        end

        function completeRun(obj)
            completeRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Restore the original holding potential (also on Stop).
            try
                if ~isempty(obj.originalHolding)
                    device = obj.rig.getDevice(obj.amp);
                    device.background = obj.originalHolding;
                    device.applyBackground();
                end
            catch e
                warning('CfPatchIvCurveFlashTrain:restoreHolding', 'Failed to restore holding potential: %s', e.message);
            end
            obj.currentLevel = [];

            try
                ledDevice = obj.rig.getDevice(obj.led);
                units = ledDevice.background.displayUnits;
                ledDevice.background = symphonyui.core.Measurement(0, units);
                ledDevice.applyBackground();
            catch e
                warning('CfPatchIvCurveFlashTrain:LedOffFailed', 'Failed to turn off LED: %s', e.message);
            end
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages * obj.pulsesInFamily;
        end

        % ---- Analysis ------------------------------------------------------

        function q = epochResponseData(obj, epoch)
            responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
            [q, ~] = responseData.getData();
            try
                [fullQ, ~] = responseData.getFullData();
                if ~isempty(fullQ), q = fullQ; end
            catch
            end
        end

        function amps = computeFlashAmplitudes(obj, q)
            %COMPUTEFLASHAMPLITUDES  Signed peak response for each flash (A).
            %   baseline_k = mean(q) over [onset_k-15, onset_k-5] ms
            %   response_k = value of (q - baseline_k) with the largest
            %                magnitude over [offset_k+5, offset_k+50] ms
            sr = obj.sampleRate;
            toPts = @(ms) round(ms / 1e3 * sr);
            prePts = toPts(obj.preTime);
            flashPts = toPts(obj.flashTime);
            onsets = obj.flashOnsetsMs();
            n = numel(onsets);
            amps = nan(1, n);
            for k = 1:n
                on  = prePts + toPts(onsets(k)) + 1;        % first flash sample
                off = on + flashPts - 1;                     % last flash sample
                blStart = on - toPts(obj.ANALYSIS_BL_START_MS);
                blEnd   = on - toPts(obj.ANALYSIS_BL_END_MS);
                rsStart = off + toPts(obj.ANALYSIS_RESP_START_MS);
                rsEnd   = off + toPts(obj.ANALYSIS_RESP_END_MS);
                if blStart < 1 || rsEnd > numel(q) || blEnd < blStart || rsEnd < rsStart
                    continue;   % leave NaN; window outside the data
                end
                baseline = mean(q(blStart:blEnd));
                dev = q(rsStart:rsEnd) - baseline;
                [~, i] = max(abs(dev));
                amps(k) = dev(i);
            end
            amps = amps(~isnan(amps));
        end

        function updateIvFigure(obj, figureHandler, epoch)
            % One epoch per holding potential: the point is the mean over the
            % step's flashes and the error bar is the SE across those flashes.
            try
                if ~obj.epochContributes(epoch), return; end
                pulseSignal = epoch.parameters('pulseSignal');
                amps = obj.computeFlashAmplitudes(obj.epochResponseData(epoch));
                if isempty(amps), return; end

                ivData = figureHandler.userData.ivData;
                ivData(pulseSignal) = amps;

                ax = figureHandler.userData.ax;
                cla(ax);
                set(ax, 'XLimMode', 'auto', 'YLimMode', 'auto');
                voltages = sort(cell2mat(ivData.keys));
                means = zeros(size(voltages));
                ses   = zeros(size(voltages));
                for i = 1:numel(voltages)
                    vals = ivData(voltages(i));
                    means(i) = mean(vals);
                    if numel(vals) > 1
                        ses(i) = std(vals) / sqrt(numel(vals));
                    end
                end
                scale = 1e12;   % A -> pA, fixed so repeats never change the axis units
                errorbar(ax, voltages, means * scale, ses * scale, 'o-', ...
                    'Color', [0 0.4470 0.7410], 'MarkerFaceColor', [0 0.4470 0.7410], ...
                    'MarkerSize', 6, 'LineWidth', 1.5, 'CapSize', 8);
                xlabel(ax, 'Holding Potential (mV)');
                ylabel(ax, 'Flash Response (pA)');
                title(ax, 'Flash Response IV (mean +/- SE across flashes in the step)');
                grid(ax, 'on');
                xlims = get(ax, 'XLim');
                line(ax, xlims, [0 0], 'Color', [0.5 0.5 0.5], 'LineStyle', '--', 'HandleVisibility', 'off');
            catch
            end
        end

        % ---- Trace figures -------------------------------------------------

        function h = newTraceFigure(obj, className, name, callback, xLabel, yLabel)
            % className must be unique per figure: FigureHandlerManager keeps
            % one handler per class, so distinct CustomFigure subclasses are used.
            h = obj.showFigure(className, callback);
            f = h.getFigureHandle();
            set(f, 'Name', name);
            delete(findall(f, 'Type', 'axes'));
            delete(findall(f, 'Type', 'legend'));
            h.userData.ax = axes('Parent', f);
            xlabel(h.userData.ax, xLabel);
            ylabel(h.userData.ax, yLabel);
            title(h.userData.ax, name);
            hold(h.userData.ax, 'on');
            grid(h.userData.ax, 'on');
            h.userData.traces = containers.Map('KeyType', 'double', 'ValueType', 'any');  % V -> struct(x, y)
        end

        function tf = epochContributes(~, ~)
            % Whether an epoch should enter the summary figures. Subclasses
            % (e.g. the adaptive protocol) override to exclude rejected steps.
            tf = true;
        end

        function c = colorForVoltage(obj, V)
            n = max(1, double(obj.pulsesInFamily));
            cmap = parula(max(n, 2));
            if obj.incrementPerPulse > 0
                idx = round((V - obj.firstPulseSignal) / obj.incrementPerPulse) + 1;
            else
                idx = 1;
            end
            idx = min(max(idx, 1), size(cmap, 1));
            c = cmap(idx, :);
        end

        function redrawTraces(obj, figureHandler)
            % Replot all stored traces, coloured by holding potential, with a legend.
            ax = figureHandler.userData.ax;
            traces = figureHandler.userData.traces;
            cla(ax);
            % cla keeps manual limit modes; make sure the axes rescale to the data.
            set(ax, 'XLimMode', 'auto', 'YLimMode', 'auto');
            voltages = sort(cell2mat(traces.keys));
            for i = 1:numel(voltages)
                tr = traces(voltages(i));
                plot(ax, tr.x, tr.y, 'Color', obj.colorForVoltage(voltages(i)), 'LineWidth', 1.2, ...
                    'DisplayName', sprintf('%+g mV', voltages(i)));
            end
            if ~isempty(voltages)
                legend(ax, 'show', 'Location', 'eastoutside');
            end
            grid(ax, 'on');
        end

        function updateRawFigure(obj, figureHandler, epoch)
            try
                if ~obj.epochContributes(epoch), return; end
                V = epoch.parameters('pulseSignal');
                q = obj.epochResponseData(epoch);
                x = (1:numel(q)) / obj.sampleRate;
                figureHandler.userData.traces(V) = struct('x', x, 'y', q * 1e12);
                obj.redrawTraces(figureHandler);
                ax = figureHandler.userData.ax;
                title(ax, 'Raw Current Response (shaded = flashes)');

                % Shade the flash windows, using THIS epoch's timing (the
                % adaptive protocol can lengthen delays between steps).
                p = epoch.parameters;
                preMs = obj.preTime;
                flashMs = obj.flashTime;
                onsetsMs = obj.flashOnsetsMs();
                try
                    if p.isKey('flashOnsets_ms')
                        onsetsMs = str2double(strsplit(strtrim(char(p('flashOnsets_ms'))), ','));
                        onsetsMs = onsetsMs(~isnan(onsetsMs));
                    end
                    if p.isKey('flashTime'), flashMs = p('flashTime'); end
                catch
                end
                yl = get(ax, 'YLim');
                for k = 1:numel(onsetsMs)
                    t0 = (preMs + onsetsMs(k)) / 1e3;             % s
                    t1 = t0 + flashMs / 1e3;
                    hp = patch(ax, [t0 t1 t1 t0], [yl(1) yl(1) yl(2) yl(2)], [1 0.85 0.3], ...
                        'EdgeColor', 'none', 'FaceAlpha', 0.25, 'HandleVisibility', 'off');
                    uistack(hp, 'bottom');
                end
                % Step onset/offset markers.
                stepMs = obj.effectiveStimTimeMs();
                try, if p.isKey('stimTime'), stepMs = p('stimTime'); end, catch, end
                line(ax, [preMs preMs] / 1e3, yl, 'Color', [0.5 0.5 0.5], 'LineStyle', ':', 'HandleVisibility', 'off');
                line(ax, [preMs + stepMs, preMs + stepMs] / 1e3, yl, 'Color', [0.5 0.5 0.5], 'LineStyle', ':', 'HandleVisibility', 'off');
                set(ax, 'XLimMode', 'auto', 'YLimMode', 'auto');   % never leave limits pinned
            catch
            end
        end

        function [t, avg, n] = flashAverage(obj, q)
            %FLASHAVERAGE  Mean across flashes of the baseline-zeroed response.
            %   Window: onset - AVG_PRE_MS to offset + AVG_POST_MS. Baseline
            %   for each flash = mean of the AVG_PRE_MS before its onset.
            sr = obj.sampleRate;
            toPts = @(ms) round(ms / 1e3 * sr);
            prePts = toPts(obj.preTime);
            flashPts = toPts(obj.flashTime);
            preWin = toPts(obj.AVG_PRE_MS);
            postWin = toPts(obj.AVG_POST_MS);
            onsets = obj.flashOnsetsMs();
            len = preWin + flashPts + postWin;
            acc = zeros(1, len);
            n = 0;
            for k = 1:numel(onsets)
                on = prePts + toPts(onsets(k)) + 1;
                i0 = on - preWin;
                i1 = on + flashPts - 1 + postWin;
                if i0 < 1 || i1 > numel(q), continue; end
                seg = q(i0:i1);
                seg = seg - mean(q(i0:on-1));   % zero the 10 ms pre-flash baseline
                acc = acc + seg;
                n = n + 1;
            end
            if n == 0
                t = []; avg = [];
                return;
            end
            avg = acc / n;
            t = ((0:len-1) - preWin) / sr * 1e3;   % ms, 0 = flash onset
        end

        function updateFlashAvgFigure(obj, figureHandler, epoch)
            try
                if ~obj.epochContributes(epoch), return; end
                V = epoch.parameters('pulseSignal');
                [t, avg, n] = obj.flashAverage(obj.epochResponseData(epoch));
                if isempty(avg), return; end
                figureHandler.userData.traces(V) = struct('x', t, 'y', avg * 1e12);
                obj.redrawTraces(figureHandler);
                ax = figureHandler.userData.ax;
                title(ax, sprintf('Flash-Averaged Response (%d flashes/step; 0 = flash onset, shaded = flash)', n));
                flashMs = obj.flashTime;
                try
                    p = epoch.parameters;
                    if p.isKey('flashTime'), flashMs = p('flashTime'); end
                catch
                end
                xl = get(ax, 'XLim');
                yl = get(ax, 'YLim');
                hp = patch(ax, [0 flashMs flashMs 0], [yl(1) yl(1) yl(2) yl(2)], [1 0.85 0.3], ...
                    'EdgeColor', 'none', 'FaceAlpha', 0.25, 'HandleVisibility', 'off');
                uistack(hp, 'bottom');
                line(ax, xl, [0 0], 'Color', [0.5 0.5 0.5], 'LineStyle', '--', 'HandleVisibility', 'off');
                set(ax, 'XLimMode', 'auto', 'YLimMode', 'auto');   % never leave limits pinned
            catch
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

    end

    methods (Access = protected)

        function enforceMinimumStimTime(obj)
            if isempty(obj.stimTime) || isempty(obj.flashTime) || isempty(obj.numberOfFlashes) || isempty(obj.interFlashInterval)
                return;
            end
            minT = obj.minimumStimTime;
            if obj.stimTime < minT
                fprintf('CfPatchIvCurveFlashTrain: step duration raised from %g to %g ms to fit %d flashes (%g ms, %g ms gaps) plus %g/%g ms baselines.\n', ...
                    obj.stimTime, minT, obj.numberOfFlashes, obj.flashTime, obj.interFlashInterval, ...
                    obj.preFlashBaselineMs(), obj.POST_FLASH_BASELINE_MS);
                obj.stimTime = minT;   % re-enters set.stimTime; already >= minT
            end
        end

    end

end
