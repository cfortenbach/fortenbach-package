classdef CfPatchTriangleWave < fortenbachlab.protocols.FortenbachLabProtocol
    % Symmetric triangle V- or I-command with onset-clean waveform and built-in Cm & Rm estimation.
    %
    % Waveform per cycle (relative to mean/offset), starting at 0 to avoid onset transient:
    %   Q1:  0  -> +A   (constant +slope)
    %   Q2: +A  ->  0   (constant -slope)
    %   Q3:  0  -> -A   (constant -slope)
    %   Q4: -A  ->  0   (constant +slope)
    %
    % Analysis uses ONLY Q1 for I_plus and Q3 for I_minus (the two constant-slope plateaus of opposite sign).
    % Cm is computed leak-robustly via half-difference; Rm is a heuristic via half-sum (see notes below).
    %
    % Notes:
    %   * For model-cell checks, set Cp Fast/Slow = 0 and Rs-Comp = 0% on the 700B.
    %   * In V-clamp, units assumed: command in mV, response in pA.

    properties
        amp                             % Output amplifier device name

        % Timing (ms)
        preTime = 50
        tailTime = 50
        period  = 200                   % full cycle (ms); will be enforced to divisible by 4 in samples

        % Shape
        amplitude = 100                 % peak magnitude (mV or pA)
        numberOfCycles = 25
        offset = 0                      % mean (mV or pA); 0 -> device background

        % Acquisition behavior
        numberOfAverages = uint16(5)    % epochs
        interpulseInterval = 0          % s

        % Generator behavior
        enforceIntegerPeriod = true     % force sample count per cycle divisible by 4
        logPredictedCurrent = true      % print slope & predicted Icap for quick sanity

        % Analysis behavior
        analysisExcludeFrac = 0.3       % exclude this fraction at each end of Q1 and Q3
        analysisMinCycles = 3           % require at least this many cycles to analyze
    end

    properties (Dependent, SetAccess = private)
        stimTime                        % ms (triangle only; excludes pre/tail)
    end

    properties (Hidden)
        ampType
    end

    methods

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()obj.createAmpStimulus());
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            dev = obj.rig.getDevice(obj.amp);
            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', dev);
            obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', dev);

            if obj.logPredictedCurrent
                slope_V_per_s = obj.computeSlope_V_per_s();
                if strcmpi(obj.ampType, 'VClamp')
                    C_pF_guess = 30;
                    Icap_pA = C_pF_guess * slope_V_per_s; % pA since pF*V/s = pA
                    obj.safeLog('info', sprintf( ...
                        'Triangle: A=%.1f mV, T=%.1f ms, slope=%.3f V/s; Icap(~%.0f pF)≈%.1f pA', ...
                        obj.amplitude, obj.period, slope_V_per_s, C_pF_guess, Icap_pA));
                else
                    units = dev.background.displayUnits;
                    units = obj.asciiUnits(units);
                    obj.safeLog('info', sprintf( ...
                        'Triangle: A=%.1f, T=%.1f ms, slope=%.3f (mode-dependent; display=%s).', ...
                        obj.amplitude, obj.period, slope_V_per_s, units));
                end
            end
        end

        function stim = createAmpStimulus(obj)
            dev = obj.rig.getDevice(obj.amp);

            gen = symphonyui.builtin.stimuli.WaveformGenerator();
            gen.sampleRate = obj.sampleRate;
            gen.units = dev.background.displayUnits;

            % Mean value (offset): if 0, track device background
            if obj.offset == 0
                meanVal = dev.background.quantity;
            else
                meanVal = obj.offset;
            end

            % --- Pre segment ---
            prePts = max(0, round((obj.preTime / 1e3) * obj.sampleRate));
            preVector = ones(1, prePts) * meanVal;

            % --- Triangle segment (exact integer samples; cycle divisible by 4) ---
            nPer = round((obj.period / 1e3) * obj.sampleRate);
            if obj.enforceIntegerPeriod
                r = mod(nPer, 4);
                if r ~= 0
                    nPer = nPer + (4 - r);  % bump to next multiple of 4
                end
            else
                nPer = max(nPer, 8);
                r = mod(nPer, 4);
                if r ~= 0, nPer = nPer + (4 - r); end
            end
            nQ = nPer / 4;  % samples per quarter

            % Build one cycle that STARTS AT 0 to avoid pre->stim step:
            % Q1: 0 -> +A  (s = +4A/T)
            % Q2: +A -> 0  (s = -4A/T)
            % Q3: 0 -> -A  (s = -4A/T)
            % Q4: -A -> 0  (s = +4A/T)
            q1 = linspace(0,              obj.amplitude,  nQ);
            q2 = linspace(obj.amplitude,  0,              nQ);
            q3 = linspace(0,             -obj.amplitude,  nQ);
            q4 = linspace(-obj.amplitude, 0,              nQ);

            % Keep all points to preserve exact nPer samples per cycle.
            oneCycle = [q1, q2, q3, q4];                           % length = nPer
            triVector = repmat(oneCycle, 1, max(1, obj.numberOfCycles));
            triVector = triVector + meanVal;

            % --- Tail segment ---
            tailPts = max(0, round((obj.tailTime / 1e3) * obj.sampleRate));
            tailVector = ones(1, tailPts) * meanVal;

            % --- Final waveform ---
            finalWaveform = [preVector, triVector, tailVector];
            gen.waveshape = finalWaveform;

            % Heads-up if command might hit ±10V rails after scaling (heuristic)
            if max(abs(finalWaveform - meanVal)) > 9.9
                obj.safeLog('warning', ...
                    'Requested command may approach/exceed typical ±10 V DAQ rails after scaling.');
            end

            stim = gen.generate();
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
            dev = obj.rig.getDevice(obj.amp);
            epoch.addStimulus(dev, obj.createAmpStimulus());
            epoch.addResponse(dev);
        end

        % === Post-epoch analysis: Cm (pF) and Rm (GΩ) using Q1 and Q3 plateaus ===
        function completeEpoch(obj, epoch)
            try
                dev = obj.rig.getDevice(obj.amp);
                resp = epoch.getResponse(dev);
                if isempty(resp)
                    obj.safeLog('warning', 'No response found for analysis.');
                    completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
                    return;
                end

                % Pull data and sample rate safely
                y = resp.getData();
                if ~isa(y, 'double'), y = double(y); end
                units = 'unknown';
                try
                    units = resp.units;
                catch
                    try
                        [~, units] = resp.getData();
                    catch
                        % keep 'unknown'
                    end
                end
                fs = [];
                try
                    fs = resp.sampleRate.quantity;  % Hz
                catch
                    try
                        fs = resp.sampleRate;         % numeric
                    catch
                    end
                end
                if isempty(fs) || fs <= 0
                    obj.safeLog('warning', 'Sample rate unavailable for analysis.');
                    completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
                    return;
                end

                % Rebuild indices to mirror generator
                prePts = max(0, round((obj.preTime / 1e3) * fs));
                nPer   = round((obj.period / 1e3) * fs);
                r = mod(nPer, 4);
                if r ~= 0, nPer = nPer + (4 - r); end
                nQ = nPer / 4;

                totalTriPts = nPer * max(1, obj.numberOfCycles);
                if numel(y) < prePts + totalTriPts
                    obj.safeLog('warning', sprintf('Response shorter than expected (%d vs %d pts).', ...
                        numel(y), prePts + totalTriPts));
                end

                % Choose central windows within Q1 (upslope) and Q3 (downslope)
                excl = min(max(obj.analysisExcludeFrac, 0), 0.49);
                qWinStart = floor(excl * nQ);
                qWinEnd   = ceil((1 - excl) * nQ) - 1;  % inclusive
                if qWinEnd <= qWinStart
                    qWinStart = floor(0.3 * nQ);
                    qWinEnd   = ceil(0.7 * nQ);
                end

                ups = []; downs = [];
                usableCycles = 0;

                for c = 0:(obj.numberOfCycles-1)
                    cycStart = prePts + c*nPer;

                    % Quarter boundaries (1-indexed)
                    q1s = cycStart + 1;           q1e = q1s + nQ - 1;
                    q2s = q1e + 1;                % q2 not used for Cm
                    q3s = q2s + nQ;               q3e = q3s + nQ - 1;
                    % q4 not used for Cm

                    if q3e > numel(y), break; end

                    % Central windows within Q1 and Q3
                    us = q1s + qWinStart;
                    ue = q1s + qWinEnd;
                    ds = q3s + qWinStart;
                    de = q3s + qWinEnd;

                    ups(end+1)   = mean(y(us:ue)); %#ok<AGROW>
                    downs(end+1) = mean(y(ds:de)); %#ok<AGROW>
                    usableCycles = usableCycles + 1;
                end

                if usableCycles < obj.analysisMinCycles
                    obj.safeLog('warning', sprintf('Only %d usable cycles; skipping Cm analysis.', usableCycles));
                    completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
                    return;
                end

                % Means across cycles
                Iplus_pA  = mean(ups);    % Q1: +slope -> +C*s (plus small leak near 0 mV)
                Iminus_pA = mean(downs);  % Q3: -slope -> -C*s (minus small leak near 0 mV)

                % Slope magnitude s = 4A/T (V/s) for V-clamp case
                s_V_per_s = obj.computeSlope_V_per_s();

                % Compute Cm (pF) from half-difference; Rm (GΩ) from half-sum (heuristic)
                Cm_pF = (Iplus_pA - Iminus_pA) / (2 * s_V_per_s);       % pF since pA / (V/s) = pF
                denom_pA = (Iplus_pA + Iminus_pA)/2;                    % pA (near 0 if centered)
                if abs(denom_pA) > eps
                    Rm_Ohms = ( (obj.amplitude/2) / 1000 ) / (denom_pA * 1e-12);  % (V)/(A) = Ω
                    Rm_GOhm = Rm_Ohms / 1e9;
                else
                    Rm_GOhm = NaN;
                end

                % Attach to epoch metadata
                epoch.addParameter('Cm_pF', Cm_pF);
                epoch.addParameter('Rm_GOhm', Rm_GOhm);
                epoch.addParameter('Iplus_pA', Iplus_pA);
                epoch.addParameter('Iminus_pA', Iminus_pA);
                epoch.addParameter('s_V_per_s', s_V_per_s);
                epoch.addParameter('respUnits', obj.asciiUnits(units));

                % Verbose readout
                obj.safeLog('info', sprintf(['Cm/Rm (n=%d cycles): ', ...
                    'Q1 I+=%.2f pA, Q3 I-=%.2f pA, s=%.3f V/s -> Cm=%.2f pF, Rm=%.2f GΩ (units=%s)'], ...
                    usableCycles, Iplus_pA, Iminus_pA, s_V_per_s, Cm_pF, Rm_GOhm, obj.asciiUnits(units)));

            catch ME
                obj.safeLog('warning', sprintf('Analysis error: %s', ME.message));
            end

            completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);
            dev = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(dev, dev.background, obj.interpulseInterval, obj.sampleRate);
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
        end

        function time = get.stimTime(obj)
            time = obj.period * obj.numberOfCycles;
        end
    end

    methods (Access = private)
        function slope = computeSlope_V_per_s(obj)
            % Triangle slope magnitude: s = 4A/T (A in volts, T in seconds).
            A_units = obj.amplitude;      % mV if V-clamp; pA if I-clamp
            if strcmpi(obj.ampType, 'VClamp')
                A_V = A_units / 1000;     % mV -> V
            else
                % In I-clamp this isn't used for Cm; kept for completeness.
                A_V = A_units / 1000;
            end
            T_s = obj.period / 1000;
            slope = 4 * A_V / T_s;        % V/s
        end

        function safeLog(obj, level, msg)
            % Log via Symphony if available; else print to MATLAB console.
            try
                if ismethod(obj, 'log')
                    obj.log(level, msg);
                else
                    fprintf('[%s] %s\n', upper(level), msg);
                end
            catch
                fprintf('[%s] %s\n', upper(level), msg);
            end
        end

        function u = asciiUnits(~, unitsIn)
            % Convert Symphony units to a plain ASCII char vector (avoid curly quotes issues)
            try
                if isstring(unitsIn)
                    u = char(unitsIn);
                elseif ischar(unitsIn)
                    u = unitsIn;
                else
                    u = char(string(unitsIn));
                end
            catch
                u = 'unknown';
            end
            % ensure ASCII only
            u = regexprep(u, '[\x80-\xFF]', '');
        end
    end
end
