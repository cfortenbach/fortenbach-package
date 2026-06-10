classdef CellHealthFigure < symphonyui.core.FigureHandler
    % CELLHEALTHFIGURE  Tracks cell health metrics across epochs.
    %
    %   Computes input resistance (Rinput) and holding current/voltage
    %   directly from the amp response on each epoch (from the embedded
    %   test pulse in pre-time) and displays two time-series subplots.
    %
    %   Rinput = V_step / I_steadystate  (Vclamp)
    %   Rinput = V_steadystate / I_step  (Iclamp)
    %
    %   With amplifier transient compensation engaged (standard practice),
    %   the capacitive transient is removed from the digitized signal, so
    %   only the steady-state (resistive) component is available. Rinput
    %   therefore reflects the total input resistance (Ra + Rm).
    %
    %   Usage in a protocol's prepareRun():
    %     obj.showFigure('fortenbachlab.figures.CellHealthFigure', ...
    %         obj.rig.getDevice(obj.amp));

    properties (SetAccess = private)
        device
    end

    properties (Access = private)
        rinputAx
        holdAx
        rinputData
        holdData
        epochCount
        clampMode   % 'Vclamp' or 'Iclamp', detected on first epoch
    end

    % Test pulse geometry (must match embedTestPulse in FortenbachLabProtocol).
    properties (Constant, Access = private)
        BASELINE_MS = 5
        PULSE_DUR_MS = 20
    end

    methods

        function obj = CellHealthFigure(device)
            obj.device = device;
            obj.rinputData = [];
            obj.holdData = [];
            obj.epochCount = 0;
            obj.clampMode = '';

            obj.createUi();
        end

        function createUi(obj)
            set(obj.figureHandle, 'Name', 'Cell Health');

            obj.rinputAx = subplot(2, 1, 1, 'Parent', obj.figureHandle);
            ylabel(obj.rinputAx, 'R_{input} (M\Omega)');
            title(obj.rinputAx, 'Input Resistance');
            grid(obj.rinputAx, 'on');

            obj.holdAx = subplot(2, 1, 2, 'Parent', obj.figureHandle);
            ylabel(obj.holdAx, 'I_{hold} (pA)');
            xlabel(obj.holdAx, 'Epoch');
            title(obj.holdAx, 'Holding Current');
            grid(obj.holdAx, 'on');
        end

        function handleEpoch(obj, epoch)
            try
                if ~epoch.hasResponse(obj.device)
                    return;
                end

                response = epoch.getResponse(obj.device);
                [quantities, ~] = response.getData();
                try
                    [fullQ, ~] = response.getFullData();
                    if ~isempty(fullQ), quantities = fullQ; end
                catch
                end
                sr = response.sampleRate.quantityInBaseUnits;

                % Detect clamp mode from the device background units.
                if isempty(obj.clampMode)
                    units = obj.device.background.displayUnits;
                    if strcmp(units, 'mV') || strcmp(units, 'V')
                        obj.clampMode = 'Vclamp';
                    else
                        obj.clampMode = 'Iclamp';
                        ylabel(obj.holdAx, 'V_{hold} (mV)');
                        title(obj.holdAx, 'Holding Voltage');
                    end
                end

                % Test pulse geometry.
                baselinePts = round(obj.BASELINE_MS / 1e3 * sr);
                pulsePts    = round(obj.PULSE_DUR_MS / 1e3 * sr);
                pulseStart  = baselinePts + 1;
                pulseEnd    = baselinePts + pulsePts;

                if baselinePts < 2 || pulseEnd > numel(quantities)
                    return;
                end

                % Baseline (before test pulse) — raw values are in base SI
                % (Amps for Vclamp response, Volts for Iclamp response).
                baseline = mean(quantities(1:baselinePts));

                % Steady-state deflection (last 80% of pulse).
                ssStart = pulseStart + round(pulsePts * 0.2);
                ssDeflection = mean(quantities(ssStart:pulseEnd)) - baseline;

                % Compute Rinput in base SI, then convert to MOhm.
                % getData() returns base SI values regardless of units label.
                %   Vclamp: R = Vstep(V) / Ideflection(A)  → Ohm
                %   Iclamp: R = Vdeflection(V) / Istep(A)  → Ohm
                % testPulseAmp: 10 mV (Vclamp) or -50 pA (Iclamp).
                if strcmp(obj.clampMode, 'Vclamp')
                    testPulseAmp_SI = 10 * 1e-3;   % 10 mV → V
                    if abs(ssDeflection) > 0
                        R_ohm = testPulseAmp_SI / ssDeflection;
                        rinputMOhm = abs(R_ohm) / 1e6;
                    else
                        rinputMOhm = NaN;
                    end
                else
                    testPulseAmp_SI = -50 * 1e-12;  % -50 pA → A
                    if abs(testPulseAmp_SI) > 0
                        R_ohm = ssDeflection / testPulseAmp_SI;
                        rinputMOhm = abs(R_ohm) / 1e6;
                    else
                        rinputMOhm = NaN;
                    end
                end

                % Scale baseline for display (A → pA, V → mV, etc.).
                [hold_val, holdUnits] = obj.siAutoScale(baseline, '');
                if strcmp(obj.clampMode, 'Vclamp')
                    holdLabel = 'I_{hold}';
                    holdTitle = 'Holding Current';
                    if isempty(holdUnits), holdUnits = 'A'; end
                else
                    holdLabel = 'V_{hold}';
                    holdTitle = 'Holding Voltage';
                    if isempty(holdUnits), holdUnits = 'V'; end
                end

                obj.epochCount = obj.epochCount + 1;
                obj.rinputData(end+1) = rinputMOhm;
                obj.holdData(end+1)   = hold_val;

                epochs = 1:obj.epochCount;

                % --- Rinput ---
                cla(obj.rinputAx);
                plot(obj.rinputAx, epochs, obj.rinputData, 'o-', 'Color', [0 0.45 0.74], ...
                    'MarkerFaceColor', [0 0.45 0.74], 'MarkerSize', 4);
                ohm = char(937);
                ylabel(obj.rinputAx, ['R_{input} (M' ohm ')']);
                if isfinite(rinputMOhm)
                    title(obj.rinputAx, sprintf('Input Resistance  (%.1f M%s)', rinputMOhm, ohm));
                else
                    title(obj.rinputAx, 'Input Resistance');
                end
                grid(obj.rinputAx, 'on');

                % --- Ihold / Vhold ---
                cla(obj.holdAx);
                plot(obj.holdAx, epochs, obj.holdData, 'o-', 'Color', [0.47 0.67 0.19], ...
                    'MarkerFaceColor', [0.47 0.67 0.19], 'MarkerSize', 4);
                xlabel(obj.holdAx, 'Epoch');
                ylabel(obj.holdAx, [holdLabel ' (' holdUnits ')']);
                if isfinite(hold_val)
                    title(obj.holdAx, sprintf('%s  (%.1f %s)', holdTitle, hold_val, holdUnits));
                else
                    title(obj.holdAx, holdTitle);
                end
                grid(obj.holdAx, 'on');

            catch ME
                fprintf(2, '[CellHealthFigure] %s\n', ME.message);
            end
        end

        function clear(obj)
            obj.rinputData = [];
            obj.holdData = [];
            obj.epochCount = 0;
            obj.clampMode = '';

            cla(obj.rinputAx);
            cla(obj.holdAx);
        end

    end

    methods (Static, Access = private)
        function [scaledData, scaledUnits] = siAutoScale(data, units)
            scaledData = data;
            scaledUnits = units;
            if isempty(data), return; end
            peak = max(abs(data(:)));
            if peak == 0 || ~isfinite(peak), return; end
            if isempty(units), units = ''; end
            siPrefixes = {'p','n',char(181),'u','m','k','M','G','T'};
            baseUnit = units;
            if numel(units) >= 2 && any(strcmp(units(1), siPrefixes))
                baseUnit = units(2:end);
            end
            if peak >= 0.1 && peak < 1e4
                scaledData = data; scaledUnits = baseUnit; return;
            end
            ex = floor(log10(peak));
            if ex <= -10
                scaledData = data * 1e12; scaledUnits = ['p' baseUnit];
            elseif ex <= -7
                scaledData = data * 1e9;  scaledUnits = ['n' baseUnit];
            elseif ex <= -4
                scaledData = data * 1e6;  scaledUnits = [char(181) baseUnit];
            elseif ex <= -1
                scaledData = data * 1e3;  scaledUnits = ['m' baseUnit];
            end
        end
    end

end
