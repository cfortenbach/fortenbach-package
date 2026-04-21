classdef CfPatchSpontaneousNoiseFft < fortenbachlab.protocols.FortenbachLabProtocol
% Spontaneous (no external stim): records for recordTime and shows:
%   - Time Trace (live)
%   - Current PSD (per-epoch, NO RMS panel)
%   - Average PSD (run-mean, WITH band RMS panel at bottom-left)
%
% Features: mains/harmonic guide lines, band-limited RMS (on average PSD),
% Welch PSD with fallback, log-safe, matched stim/acq Fs, throttled epochs,
% robust UI (try/catch).

    % -------- USER PARAMS --------
    properties
        amp                             % Input amplifier
        mode = 'Vc'                     % 'Vc' or 'Ic' (label only)
        holding = 0                     % Holding potential: 0 mV (Vc) or 0 pA (Ic)
        recordTime = 5000               % Recording duration per epoch (ms)

        subtractMean = true
        detrendLinear = true
        useWelch = true
        welchWindowMs = 1000            % Welch window length (ms)
        welchOverlapFrac = 0.5          % Welch overlap fraction (0..0.9)

        showLiveFigure = true
        showBuiltIns = false            % Show Symphony built-in response figures

        % Guides + band RMS (RMS shown on Average PSD ONLY)
        showGuides = true
        mainsFreqHz = 60                % Mains frequency for guide lines (Hz)
        numHarmonics = 10               % Number of harmonic guide lines
        rmsBands_Hz = [  0     10;
                         10    100;
                         100   1000;
                         1000  5000;
                         55    65;
                         115   125 ]
        showBandTableInConsole = true
    end

    properties
        numberOfAverages = uint16(5)    % Number of epochs
    end

    % -------- INTERNAL --------
    properties (Hidden)
        ampType
        fsHz
        defaultFsHz = 20000
        welchWindow
        welchOverlap
        runPsdAccum
        runPsdCount = 0

        % Current PSD figure
        curFig
        curAx

        % Average PSD figure (with RMS panel)
        avgFig
        avgAx
        rmsPanelH = []

        % Time-trace figure
        liveRawFig
        liveRawAx

        freqAxis
        unitsStr
        maxInFlight = 1
    end

    methods

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Set holding background.
            device = obj.rig.getDevice(obj.amp);
            if strcmpi(obj.mode, 'Vc'), u = 'mV'; else, u = 'pA'; end
            device.background = symphonyui.core.Measurement(obj.holding, u);

            % Reset state.
            obj.welchWindow = []; obj.welchOverlap = [];
            obj.runPsdAccum = []; obj.runPsdCount = 0;
            obj.freqAxis = []; obj.unitsStr = ''; obj.fsHz = [];
            obj.rmsPanelH = [];

            obj.showFigure('fortenbachlab.figures.CellHealthFigure', obj.rig.getDevice(obj.amp));

            % Optional built-ins.
            if obj.showBuiltIns
                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', device);
                obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', device);
            end

            % Custom figure windows.
            if obj.showLiveFigure
                basePos = get(0, 'DefaultFigurePosition');

                obj.curFig = figure('Name', 'Current PSD (Welch)', 'NumberTitle', 'off', 'Visible', 'on');
                try, set(obj.curFig, 'Position', basePos + [40 -40 0 0]); catch, end
                obj.curAx = axes('Parent', obj.curFig); grid(obj.curAx, 'on');
                xlabel(obj.curAx, 'Frequency (Hz)'); ylabel(obj.curAx, 'Power / Hz');
                title(obj.curAx, 'Current PSD (waiting...)');

                obj.avgFig = figure('Name', 'Average PSD (Welch)', 'NumberTitle', 'off', 'Visible', 'on');
                try, set(obj.avgFig, 'Position', basePos + [520 -40 0 0]); catch, end
                obj.avgAx = axes('Parent', obj.avgFig); grid(obj.avgAx, 'on');
                xlabel(obj.avgAx, 'Frequency (Hz)'); ylabel(obj.avgAx, 'Power / Hz');
                title(obj.avgAx, 'Average PSD (waiting...)');

                obj.liveRawFig = figure('Name', 'Time Trace', 'NumberTitle', 'off', 'Visible', 'on');
                try, set(obj.liveRawFig, 'Position', basePos + [1000 -40 0 0]); catch, end
                obj.liveRawAx = axes('Parent', obj.liveRawFig); grid(obj.liveRawAx, 'on');
                xlabel(obj.liveRawAx, 'Time (s)'); ylabel(obj.liveRawAx, 'Response');
                title(obj.liveRawAx, 'Time Trace (waiting...)');
            end

            fprintf('[CF_Spontaneous_Noise_FFT] Amp=%s, mode=%s, holding=%g %s, T=%.2fs, n=%d\n', ...
                obj.amp, upper(obj.mode), obj.holding, u, obj.recordTime/1000, obj.numberOfAverages);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            device = obj.rig.getDevice(obj.amp);
            epoch.addResponse(device);

            % Build a DC stimulus with test pulse at the start.
            bg = device.background.quantity;
            units = device.background.displayUnits;
            totalPts = round(obj.recordTime / 1e3 * obj.sampleRate);
            data = ones(1, totalPts) * bg;
            data = obj.embedTestPulse(data, obj.amp);
            epoch.addStimulus(device, obj.createStimulusFromArray(data, units));
        end

        function tf = shouldContinuePreparingEpochs(obj)
            inflight = obj.numEpochsPrepared - obj.numEpochsCompleted;
            tf = obj.numEpochsPrepared < obj.numberOfAverages && inflight < obj.maxInFlight;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
        end

        function completeEpoch(obj, epoch)
            try
                % Re-create windows if user closed them.
                if obj.showLiveFigure
                    if isempty(obj.curFig) || ~ishandle(obj.curFig)
                        obj.curFig = figure('Name', 'Current PSD (Welch)', 'NumberTitle', 'off');
                        obj.curAx = axes('Parent', obj.curFig); grid(obj.curAx, 'on');
                    end
                    if isempty(obj.avgFig) || ~ishandle(obj.avgFig)
                        obj.avgFig = figure('Name', 'Average PSD (Welch)', 'NumberTitle', 'off');
                        obj.avgAx = axes('Parent', obj.avgFig); grid(obj.avgAx, 'on');
                        obj.rmsPanelH = [];
                    end
                    if isempty(obj.liveRawFig) || ~ishandle(obj.liveRawFig)
                        obj.liveRawFig = figure('Name', 'Time Trace', 'NumberTitle', 'off');
                        obj.liveRawAx = axes('Parent', obj.liveRawFig); grid(obj.liveRawAx, 'on');
                    end
                end

                % Read response.
                device = obj.rig.getDevice(obj.amp);
                [y, units, fs] = obj.getResponseData_(epoch, device);

                if isempty(obj.fsHz) && ~isempty(fs) && isfinite(fs) && fs > 0
                    obj.fsHz = fs;
                    [obj.welchWindow, obj.welchOverlap] = obj.finalizeWelchParams_(obj.fsHz);
                end
                if isempty(obj.fsHz)
                    obj.fsHz = obj.defaultFsHz;
                    [obj.welchWindow, obj.welchOverlap] = obj.finalizeWelchParams_(obj.fsHz);
                end
                if isempty(obj.unitsStr), obj.unitsStr = units; end

                % Time Trace.
                if obj.showLiveFigure && ~isempty(obj.liveRawAx) && isvalid(obj.liveRawAx)
                    try
                        N = numel(y); t = (0:N-1) / obj.fsHz;
                        cla(obj.liveRawAx); plot(obj.liveRawAx, t, y);
                        xlabel(obj.liveRawAx, 'Time (s)');
                        ylabel(obj.liveRawAx, sprintf('Response (%s)', obj.unitsStr));
                        title(obj.liveRawAx, 'Time Trace'); grid(obj.liveRawAx, 'on'); drawnow;
                    catch, end
                end

                % Preprocess.
                if obj.detrendLinear, y = detrend(y, 1); end
                if obj.subtractMean, y = y - mean(y); end
                if numel(y) < 2, return; end

                % Welch PSD.
                if obj.useWelch && exist('pwelch', 'file') == 2
                    try
                        [psd, f] = pwelch(y, obj.welchWindow, obj.welchOverlap, [], obj.fsHz, 'onesided');
                    catch
                        [psd, f] = obj.welchFallback_(y, obj.fsHz, obj.welchWindow, obj.welchOverlap);
                    end
                else
                    [psd, f] = obj.welchFallback_(y, obj.fsHz, obj.welchWindow, obj.welchOverlap);
                end
                f = f(:); psd = psd(:); psd(~isfinite(psd) | psd <= 0) = eps;

                % Save per-epoch.
                epoch.addParameter('welchFreq_Hz', f);
                epoch.addParameter('welchPSD', psd);
                epoch.addParameter('Fs_Hz', obj.fsHz);

                % Accumulate run-mean.
                if isempty(obj.runPsdAccum)
                    obj.runPsdAccum = psd; obj.freqAxis = f;
                else
                    L = min(numel(obj.runPsdAccum), numel(psd));
                    obj.runPsdAccum = obj.runPsdAccum(1:L) + psd(1:L);
                    obj.freqAxis = obj.freqAxis(1:L);
                end
                obj.runPsdCount = obj.runPsdCount + 1;

                % Plot Current PSD.
                if obj.showLiveFigure && ~isempty(obj.curAx) && isvalid(obj.curAx)
                    try
                        cla(obj.curAx);
                        loglog(obj.curAx, f, psd); hold(obj.curAx, 'on');
                        if obj.showGuides, obj.drawGuideLines_(obj.curAx); end
                        hold(obj.curAx, 'off');
                        xlabel(obj.curAx, 'Frequency (Hz)'); ylabel(obj.curAx, 'Power / Hz');
                        title(obj.curAx, 'Current PSD'); grid(obj.curAx, 'on'); drawnow;
                    catch, end
                end

                % Plot Average PSD with RMS panel.
                if obj.showLiveFigure && ~isempty(obj.avgAx) && isvalid(obj.avgAx)
                    try
                        cla(obj.avgAx);
                        avg = obj.runPsdAccum / max(1, obj.runPsdCount);
                        loglog(obj.avgAx, obj.freqAxis, avg, 'LineWidth', 1.5); hold(obj.avgAx, 'on');
                        if obj.showGuides, obj.drawGuideLines_(obj.avgAx); end
                        hold(obj.avgAx, 'off');
                        xlabel(obj.avgAx, 'Frequency (Hz)'); ylabel(obj.avgAx, 'Power / Hz');
                        title(obj.avgAx, 'Average PSD'); grid(obj.avgAx, 'on'); drawnow;

                        [bandsClipped, rmsVals] = obj.computeBandRms_(f, psd, obj.fsHz/2, obj.rmsBands_Hz);
                        if obj.showBandTableInConsole, obj.printBandTable_(bandsClipped, rmsVals); end
                        obj.updateRmsPanel_(obj.avgAx, bandsClipped, rmsVals);
                    catch, end
                end

            catch ME
                fprintf(2, '[NoiseFFT] completeEpoch error: %s\n', ME.message);
            end

            % Compute and save cell health metrics from the test pulse.
            try
                testAmp = obj.testPulseAmplitude(obj.amp);
                metrics = obj.computeCellHealthMetrics(epoch, obj.amp, testAmp, 5, 20);
                obj.saveCellHealthMetrics(epoch, metrics);
            catch
            end

            completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
        end

    end

    methods (Access = private)

        function [y, units, fs] = getResponseData_(obj, epoch, device)
            r = epoch.getResponse(device);
            units = 'unknown'; try, units = r.units; catch, end
            fs = [];
            try, [y, ~] = r.getData(); catch, y = r.getData(); end
            if isrow(y), y = y(:); end
            try
                sr = r.sampleRate;
                if isa(sr, 'symphonyui.core.Measurement'), fs = sr.quantityInBaseUnits; else, fs = double(sr); end
            catch
                N = numel(y); T = max(1, round(obj.recordTime / 1000)); fs = N / T;
            end
            useFs = obj.fsHz;
            if isempty(useFs) || ~isfinite(useFs) || useFs <= 0, useFs = fs; end
            if ~isempty(useFs) && isfinite(useFs) && useFs > 0
                want = round((obj.recordTime / 1000) * useFs);
                if numel(y) > want, y = y(1:want); end
            end
        end

        function [wlen, ov] = finalizeWelchParams_(obj, fs)
            wlen = max(4, round(obj.welchWindowMs / 1000 * fs));
            ov = max(0, min(round(wlen * obj.welchOverlapFrac), wlen - 1));
        end

        function [Pxx, f] = welchFallback_(obj, x, Fs, wlen, ov)
            x = x(:); step = max(1, wlen - ov);
            nSeg = max(1, floor((numel(x) - ov) / step));
            w = obj.safeHann_(wlen); U = sum(w.^2) / wlen;
            acc = []; K = 0;
            for k = 1:nSeg
                i0 = (k-1)*step + 1; i1 = min(i0 + wlen - 1, numel(x));
                if (i1 - i0 + 1) < wlen, break; end
                Xk = fft(x(i0:i1) .* w); Pk = (abs(Xk).^2) / (wlen * Fs * U);
                L = floor(wlen/2) + 1; Pk = 2 * Pk(1:L);
                if isempty(acc), acc = Pk; else, acc = acc + Pk; end
                K = K + 1;
            end
            if K == 0, L = floor(wlen/2) + 1; acc = zeros(L, 1); K = 1; end
            Pxx = acc / K; f = (0:(numel(Pxx)-1))' * (Fs / wlen);
        end

        function w = safeHann_(~, wlen)
            if exist('hann', 'file') == 2
                w = hann(wlen, 'periodic');
            else
                n = (0:wlen-1)'; w = 0.5 - 0.5 * cos(2*pi*n / (wlen-1));
            end
        end

        function drawGuideLines_(obj, ax)
            if obj.mainsFreqHz <= 0, return; end
            nyq = obj.fsHz / 2;
            for k = 1:obj.numHarmonics
                fk = k * obj.mainsFreqHz;
                if fk > nyq, break; end
                try
                    xline(ax, fk, '--', 'Color', [0.7 0.7 0.7]);
                catch
                    yl = ylim(ax); plot(ax, [fk fk], yl, '--', 'Color', [0.7 0.7 0.7]); ylim(ax, yl);
                end
            end
        end

        function [bandsOut, rmsVals] = computeBandRms_(~, f, psd, nyquistHz, bands)
            if isempty(bands), bandsOut = zeros(0, 2); rmsVals = zeros(0, 1); return; end
            nB = size(bands, 1);
            outB = zeros(0, 2); outR = zeros(0, 1);
            for i = 1:nB
                lo = max(0, min(bands(i,1), nyquistHz));
                hi = max(0, min(bands(i,2), nyquistHz));
                if hi <= lo, continue; end
                idx = (f >= lo) & (f <= hi);
                if ~any(idx)
                    [~, ilo] = min(abs(f - lo)); [~, ihi] = min(abs(f - hi));
                    idx = false(size(f)); idx(min(ilo, ihi):max(ilo, ihi)) = true;
                end
                varBand = trapz(f(idx), psd(idx));
                outB(end+1,:) = [lo hi]; %#ok<AGROW>
                outR(end+1,1) = sqrt(max(varBand, 0)); %#ok<AGROW>
            end
            bandsOut = outB; rmsVals = outR;
        end

        function printBandTable_(~, bands, rmsVals)
            if isempty(bands), return; end
            fprintf('--- Band-limited RMS ---\n');
            for i = 1:size(bands, 1)
                fprintf('  [%7.2f %7.2f] Hz : RMS = %.6g\n', bands(i,1), bands(i,2), rmsVals(i));
            end
        end

        function updateRmsPanel_(obj, axForPanel, bands, rmsVals)
            if isempty(axForPanel) || ~isvalid(axForPanel), return; end
            if isempty(bands)
                msg = 'Band RMS: (no bands)';
            else
                lines = cell(size(bands, 1) + 1, 1);
                lines{1} = 'Band RMS (units rms):';
                for i = 1:size(bands, 1)
                    lines{i+1} = sprintf('[%g-%g] Hz: %.3g', bands(i,1), bands(i,2), rmsVals(i));
                end
                msg = strjoin(lines, '\n');
            end
            try
                fig = ancestor(axForPanel, 'figure');
                if isempty(obj.rmsPanelH) || ~ishandle(obj.rmsPanelH)
                    obj.rmsPanelH = annotation(fig, 'textbox', [0.12 0.12 0.36 0.25], ...
                        'String', char(msg), 'Interpreter', 'none', 'EdgeColor', [0.7 0.7 0.7], ...
                        'BackgroundColor', [1 1 1], 'Margin', 6, 'FontSize', 9);
                else
                    set(obj.rmsPanelH, 'String', char(msg));
                end
            catch, end
        end

    end

end
