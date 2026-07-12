classdef CfPatchPairedFlash < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents one or more LED flashes with logarithmically spaced
    % inter-flash intervals and records from a specified amplifier.
    %
    % For a classic paired-pulse experiment, set numberOfFlashes = 2.
    % The first inter-flash interval is interFlashInterval (ms), measured
    % from the END of one flash to the START of the next.  Each successive
    % gap is multiplied by intervalFactor, so with intervalFactor = 2 the
    % gaps double each time — producing intervals that are evenly spaced
    % on a logarithmic time axis.
    %
    % Example (numberOfFlashes = 4, flashTime = 10, interFlashInterval = 100,
    %          intervalFactor = 2, preTime = 50):
    %
    %   |--pre--|  F1  |--100--|  F2  |---200---|  F3  |------400------|  F4  |--tail--|
    %   0      50  60   160  170       370  380                780  790
    %
    % The epoch duration is computed automatically from the flash train
    % plus the user-set preTime and tailTime.

    properties
        led                             % Output LED
        preTime = 100                   % Pre-flash baseline (ms)
        flashTime = 10                  % Duration of each flash (ms)
        tailTime = 3000                 % Post-last-flash tail (ms)
        numberOfFlashes = uint16(2)     % Number of flashes per epoch
        interFlashInterval = 500        % Gap: end of flash n to start of flash n+1 (ms)
        intervalFactor = 2              % Multiplier applied to each successive gap
        lightAmplitude = 5              % Flash amplitude (V or norm. [0-1] depending on LED units)
        lightMean = 0                   % Background amplitude: LED DC voltage (V or norm. [0-1])
        ndf = 0.0                       % ND filter setting
        numberOfAverages = uint16(5)    % Number of epochs
        interpulseInterval = 0          % Duration between pulses (s)
        amp                             % Input amplifier
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Dependent)
        flashIntensity                  % Flash intensity (photons/cm2/s). Accepts scientific notation.
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
        recoveryFigure
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

            % Consistent display names for LED properties.
            if strcmp(name, 'lightAmplitude')
                d.displayName = 'Flash Amplitude';
            end
            if strcmp(name, 'lightMean')
                d.displayName = 'Background Amplitude';
            end

            % Hide multi-flash fields when there is only one flash.
            if obj.numberOfFlashes <= 1 && ...
                    (strcmp(name, 'interFlashInterval') || strcmp(name, 'intervalFactor'))
                d.isHidden = true;
            end

            % Hide intervalFactor when there are only two flashes (only one gap).
            if obj.numberOfFlashes == 2 && strcmp(name, 'intervalFactor')
                d.isHidden = true;
            end

            % Constrain NDF to valid filter wheel values.
            if strcmp(name, 'ndf')
                d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', ...
                    {0, 0.5, 1.0, 2.0, 3.0, 4.0});
            end

            % Treat intensity fields as editable strings so scientific
            % notation input (e.g. "1.5e15") is accepted and displayed.
            if strcmp(name, 'flashIntensity') || strcmp(name, 'backgroundIntensity')
                d.type = symphonyui.core.PropertyType('char', 'row');
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()obj.createLedStimulus());
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            trainDur = obj.computeTrainDuration();

            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('fortenbachlab.figures.ResponseStimulusFigure', ...
                    obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.led));
                obj.showFigure('fortenbachlab.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp), ...
                    'ledDevice', obj.rig.getDevice(obj.led));
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime + trainDur]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, obj.rig.getDevice(obj.amp2), {@mean, @var}, ...
                    'baselineRegion1', [0 obj.preTime], ...
                    'measurementRegion1', [obj.preTime obj.preTime + trainDur], ...
                    'baselineRegion2', [0 obj.preTime], ...
                    'measurementRegion2', [obj.preTime obj.preTime + trainDur]);
            end

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
                warning('CfPatchPairedFlash:setNDFFailed', ...
                    'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
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
                    'ledDevice', obj.rig.getDevice(obj.led));
            end

            obj.showFigure('fortenbachlab.figures.ProgressFigure', obj.numberOfAverages, ...
                'flashVoltages', obj.lightAmplitude, ...
                'flashNdfs', obj.ndf, ...
                'flashFluxes', obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, obj.ndf));

            % --- Recovery figure (multi-flash only) ---
            if obj.numberOfFlashes > 1
                obj.recoveryFigure = obj.showFigure( ...
                    'symphonyui.builtin.figures.CustomFigure', @obj.updateRecoveryFigure);
                rf = obj.recoveryFigure.getFigureHandle();
                set(rf, 'Name', 'Recovery');
                obj.recoveryFigure.userData.ax = axes('Parent', rf);
                xlabel(obj.recoveryFigure.userData.ax, 'Time from conditioning flash (ms)');
                ylabel(obj.recoveryFigure.userData.ax, 'R_n / R_1');
                title(obj.recoveryFigure.userData.ax, 'Recovery');
                hold(obj.recoveryFigure.userData.ax, 'on');
                grid(obj.recoveryFigure.userData.ax, 'on');
                set(obj.recoveryFigure.userData.ax, 'XScale', 'log');
                obj.recoveryFigure.userData.recoveryData = ...
                    containers.Map('KeyType', 'double', 'ValueType', 'any');
            end
        end

        function stim = createLedStimulus(obj)
            % Build LED waveform: background at lightMean with N flashes
            % of lightAmplitude, spaced by logarithmically increasing gaps.
            device = obj.rig.getDevice(obj.led);
            units = device.background.displayUnits;
            sr = obj.sampleRate;

            [onsets, trainDur] = obj.computeFlashOnsets();
            totalMs  = obj.preTime + trainDur + obj.tailTime;
            totalPts = round(totalMs / 1e3 * sr);

            data = ones(1, totalPts) * obj.lightMean;
            flashPts = round(obj.flashTime / 1e3 * sr);

            for i = 1:numel(onsets)
                onPt  = round(onsets(i) / 1e3 * sr) + 1;
                offPt = min(onPt + flashPts - 1, totalPts);
                data(onPt:offPt) = obj.lightMean + obj.lightAmplitude;
            end

            stim = obj.createStimulusFromArray(data, units);
        end

        function stim = createAmpTestPulseStimulus(obj)
            % Flat amp stimulus at background with a test pulse embedded
            % in pre-time for cell health monitoring.
            device = obj.rig.getDevice(obj.amp);
            bg    = device.background.quantity;
            units = device.background.displayUnits;

            trainDur = obj.computeTrainDuration();
            totalMs  = obj.preTime + trainDur + obj.tailTime;
            totalPts = round(totalMs / 1e3 * obj.sampleRate);

            data = ones(1, totalPts) * bg;
            data = obj.embedTestPulse(data, obj.amp);
            stim = obj.createStimulusFromArray(data, units);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
            if obj.cellHealthEnabled()
                epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpTestPulseStimulus());
            end
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            % Record stimulus parameters to epoch metadata.
            epoch.addParameter('ndf', obj.ndf);
            epoch.addParameter('numberOfFlashes', double(obj.numberOfFlashes));
            epoch.addParameter('interFlashInterval', obj.interFlashInterval);
            epoch.addParameter('intervalFactor', obj.intervalFactor);
            epoch.addParameter('photonFluxPeak', obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, obj.ndf));
            epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, obj.ndf));

            [onsets, ~] = obj.computeFlashOnsets();
            epoch.addParameter('flashOnsetTimes', onsets);

            if obj.numberOfFlashes > 1
                gaps = obj.computeGaps();
                epoch.addParameter('interFlashIntervals', gaps);
            end

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function completeEpoch(obj, epoch)
            % Compute per-flash peak responses and save to epoch metadata.
            if obj.numberOfFlashes > 1
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
                        peaks = obj.computeFlashResponses(quantities);
                        epoch.addParameter('flashPeakResponses', peaks);
                        if abs(peaks(1)) > 0
                            epoch.addParameter('recoveryRatios', abs(peaks(2:end)) / abs(peaks(1)));
                        end
                    end
                catch
                end
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

            device = obj.rig.getDevice(obj.led);
            interval.addDirectCurrentStimulus(device, device.background, obj.interpulseInterval, obj.sampleRate);
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
        end

        % ================================================================
        %  RECOVERY FIGURE CALLBACK
        % ================================================================

        function updateRecoveryFigure(obj, figureHandler, epoch)
            % Measures the peak response to each flash, normalizes to
            % flash 1, accumulates across epochs, fits a single-exponential
            % recovery time constant, and plots the result.
            try
                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, ~] = responseData.getData();
                try
                    [fullQ, ~] = responseData.getFullData();
                    if ~isempty(fullQ), quantities = fullQ; end
                catch
                end

                peaks = obj.computeFlashResponses(quantities);

                % Normalize to conditioning flash (flash 1).
                if abs(peaks(1)) < eps, return; end
                ratios = abs(peaks(2:end)) / abs(peaks(1));

                % Delays: time from end of flash 1 to start of each test flash.
                [onsets, ~] = obj.computeFlashOnsets();
                flash1End = onsets(1) + obj.flashTime;
                delays = onsets(2:end) - flash1End;   % ms

                % Accumulate across epochs.
                rData = figureHandler.userData.recoveryData;
                for i = 1:numel(delays)
                    key = delays(i);
                    if rData.isKey(key)
                        rData(key) = [rData(key), ratios(i)];
                    else
                        rData(key) = ratios(i);
                    end
                end

                % Compute means and SEs at each delay.
                delayKeys = sort(cell2mat(rData.keys));
                nPts      = numel(delayKeys);
                meanR     = zeros(1, nPts);
                seR       = zeros(1, nPts);
                for i = 1:nPts
                    vals    = rData(delayKeys(i));
                    meanR(i) = mean(vals);
                    if numel(vals) > 1
                        seR(i) = std(vals) / sqrt(numel(vals));
                    end
                end

                % --- Fit single-exponential recovery ---
                %   model: R(t)/R1 = A * (1 - exp(-t / tau))
                %   A  = asymptotic recovery level (~1 for full recovery)
                %   tau = recovery time constant (ms)
                tauStr = '';
                tauFit = [];
                aFit   = [];
                if nPts >= 1 && all(isfinite(meanR))
                    try
                        if nPts == 1
                            % Single data point: solve directly (assume A=1).
                            if meanR(1) < 1 && meanR(1) > 0
                                tauFit = -delayKeys(1) / log(1 - meanR(1));
                                aFit   = 1;
                            end
                        else
                            % Two-parameter fit via fminsearch.
                            costFn = @(p) sum((meanR - p(1) * (1 - exp(-delayKeys / p(2)))).^2);
                            p0   = [max(meanR), median(delayKeys)];
                            opts = optimset('Display', 'off', 'MaxFunEvals', 2000, ...
                                            'MaxIter', 1000, 'TolX', 1e-6, 'TolFun', 1e-8);
                            p = fminsearch(costFn, p0, opts);
                            aFit   = p(1);
                            tauFit = p(2);
                        end

                        if ~isempty(tauFit) && isfinite(tauFit) && tauFit > 0
                            if tauFit >= 1000
                                tauStr = sprintf('\\tau = %.2f s', tauFit / 1000);
                            else
                                tauStr = sprintf('\\tau = %.1f ms', tauFit);
                            end
                        end
                    catch
                    end
                end

                % --- Plot ---
                ax = figureHandler.userData.ax;
                cla(ax);

                errorbar(ax, delayKeys, meanR, seR, 'o', ...
                    'Color', [0 0.4470 0.7410], ...
                    'MarkerFaceColor', [0 0.4470 0.7410], ...
                    'MarkerSize', 6, 'LineWidth', 1.5, 'CapSize', 8);

                % Overlay exponential fit curve.
                if ~isempty(tauFit) && tauFit > 0 && ~isempty(aFit)
                    tFit = logspace(log10(max(1, min(delayKeys) * 0.5)), ...
                                    log10(max(delayKeys) * 1.5), 200);
                    rFit = aFit * (1 - exp(-tFit / tauFit));
                    plot(ax, tFit, rFit, '-', 'Color', [0.85 0.33 0.10], 'LineWidth', 1.5);
                end

                set(ax, 'XScale', 'log');
                xlabel(ax, 'Time from conditioning flash (ms)');
                ylabel(ax, 'R_n / R_1');
                if ~isempty(tauStr)
                    title(ax, ['Recovery:  ' tauStr]);
                else
                    title(ax, 'Recovery');
                end
                grid(ax, 'on');

                % Full-recovery reference line at y = 1.
                xlims = get(ax, 'XLim');
                line(ax, xlims, [1 1], 'Color', [0.5 0.5 0.5], ...
                    'LineStyle', '--', 'HandleVisibility', 'off');
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

        function set.flashIntensity(obj, val)
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
                warning('CfPatchPairedFlash:NoCalibration', ...
                    'LED calibration not loaded; cannot set flashIntensity.');
                return;
            end
            vPeak = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf);
            if isnan(vPeak), vPeak = 10; end
            newAmplitude = vPeak - obj.lightMean;
            if newAmplitude < 0, newAmplitude = 0; end
            obj.lightAmplitude = newAmplitude;
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
                warning('CfPatchPairedFlash:NoCalibration', ...
                    'LED calibration not loaded; cannot set backgroundIntensity.');
                return;
            end
            vMean = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf);
            if isnan(vMean), vMean = 10; end
            if vMean < 0, vMean = 0; end
            obj.lightMean = vMean;
        end

        function s = get.flashIntensity(obj)
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

        function s = get.backgroundIntensity(obj)
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

    end

    % ====================================================================
    %  PRIVATE HELPERS
    % ====================================================================
    methods (Access = private)

        function peaks = computeFlashResponses(obj, quantities)
            %COMPUTEFLASHRESPONSES  Peak response to each flash.
            %   For each flash, computes a local baseline from the window
            %   immediately before flash onset, then finds the signed peak
            %   deviation within a response window after onset.  The
            %   response window extends to the start of the next flash (or
            %   up to 200 ms, whichever is shorter) to prevent overlap.
            sr = obj.sampleRate;
            [onsets, ~] = obj.computeFlashOnsets();
            gaps = obj.computeGaps();
            n = numel(onsets);
            peaks = zeros(1, n);

            maxWindow = 200;   % ms — maximum response analysis window

            for i = 1:n
                onsetPt = round(onsets(i) / 1e3 * sr) + 1;

                % --- Local baseline: up to 20 ms before this flash ---
                if i == 1
                    blMs = min(20, double(obj.preTime));
                else
                    blMs = min(20, gaps(i - 1));
                end
                blPts   = round(blMs / 1e3 * sr);
                blStart = max(1, onsetPt - blPts);
                blEnd   = max(1, onsetPt - 1);
                baseline = mean(quantities(blStart:blEnd));

                % --- Response window ---
                if i < n
                    availMs = onsets(i + 1) - onsets(i);
                else
                    availMs = obj.flashTime + min(double(obj.tailTime), maxWindow);
                end
                windowMs  = min(availMs, maxWindow);
                windowPts = round(windowMs / 1e3 * sr);
                respEnd   = min(onsetPt + windowPts - 1, numel(quantities));

                if onsetPt > numel(quantities), continue; end

                deviation = quantities(onsetPt:respEnd) - baseline;
                [~, maxIdx] = max(abs(deviation));
                peaks(i) = deviation(maxIdx);   % signed peak (base SI)
            end
        end

        function gaps = computeGaps(obj)
            %COMPUTEGAPS  Inter-flash gaps in ms (logarithmically spaced).
            %   gaps(i) = interFlashInterval * intervalFactor^(i-1)
            n = double(obj.numberOfFlashes);
            if n <= 1
                gaps = [];
                return;
            end
            gaps = obj.interFlashInterval * obj.intervalFactor .^ (0:n-2);
        end

        function dur = computeTrainDuration(obj)
            %COMPUTETRAINDURATION  Total flash train duration in ms.
            %   = N * flashTime + sum(gaps)
            n = double(obj.numberOfFlashes);
            dur = n * obj.flashTime;
            if n > 1
                dur = dur + sum(obj.computeGaps());
            end
        end

        function [onsets, trainDur] = computeFlashOnsets(obj)
            %COMPUTEFLASHONSETS  Flash onset times in ms from epoch start.
            %   Also returns the total train duration.
            n    = double(obj.numberOfFlashes);
            gaps = obj.computeGaps();

            onsets = zeros(1, n);
            t = obj.preTime;          % first flash starts at preTime
            for i = 1:n
                onsets(i) = t;
                t = t + obj.flashTime; % advance past this flash
                if i < n
                    t = t + gaps(i);   % advance past the gap
                end
            end
            trainDur = t - obj.preTime;
        end

    end

end
