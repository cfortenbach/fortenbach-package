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

                % Test pulse amplitude (must match FortenbachLabProtocol).
                if strcmp(obj.clampMode, 'Vclamp')
                    testPulseAmp = 10;  % mV
                else
                    testPulseAmp = -50; % pA
                end

                % Baseline (before test pulse).
                baseline = mean(quantities(1:baselinePts));

                % Steady-state deflection (last 80% of pulse — with
                % amplifier transient compensation the response settles
                % within the first sample, so we can safely average
                % nearly the entire pulse).
                ssStart = pulseStart + round(pulsePts * 0.2);
                ssDeflection = mean(quantities(ssStart:pulseEnd)) - baseline;

                % Compute Rinput.
                % Vclamp: Rinput = Vstep (mV) / Iss (pA) * 1000 -> MOhm
                % Iclamp: Rinput = Vss (mV)  / Istep (pA) * 1000 -> MOhm
                if strcmp(obj.clampMode, 'Vclamp')
                    if abs(ssDeflection) > 0
                        rinputMOhm = abs(testPulseAmp / ssDeflection) * 1000;
                    else
                        rinputMOhm = NaN;
                    end
                else
                    if abs(testPulseAmp) > 0
                        rinputMOhm = abs(ssDeflection / testPulseAmp) * 1000;
                    else
                        rinputMOhm = NaN;
                    end
                end

                hold_val = baseline;

                obj.epochCount = obj.epochCount + 1;
                obj.rinputData(end+1) = rinputMOhm;
                obj.holdData(end+1)   = hold_val;

                epochs = 1:obj.epochCount;

                % --- Rinput ---
                cla(obj.rinputAx);
                plot(obj.rinputAx, epochs, obj.rinputData, 'o-', 'Color', [0 0.45 0.74], ...
                    'MarkerFaceColor', [0 0.45 0.74], 'MarkerSize', 4);
                ylabel(obj.rinputAx, 'R_{input} (M\Omega)');
                if isfinite(rinputMOhm)
                    title(obj.rinputAx, sprintf('Input Resistance  (%.1f M\\Omega)', rinputMOhm));
                else
                    title(obj.rinputAx, 'Input Resistance');
                end
                grid(obj.rinputAx, 'on');

                % --- Ihold / Vhold ---
                cla(obj.holdAx);
                plot(obj.holdAx, epochs, obj.holdData, 'o-', 'Color', [0.47 0.67 0.19], ...
                    'MarkerFaceColor', [0.47 0.67 0.19], 'MarkerSize', 4);
                xlabel(obj.holdAx, 'Epoch');
                if strcmp(obj.clampMode, 'Iclamp')
                    ylabel(obj.holdAx, 'V_{hold} (mV)');
                    if isfinite(hold_val)
                        title(obj.holdAx, sprintf('Holding Voltage  (%.1f mV)', hold_val));
                    else
                        title(obj.holdAx, 'Holding Voltage');
                    end
                else
                    ylabel(obj.holdAx, 'I_{hold} (pA)');
                    if isfinite(hold_val)
                        title(obj.holdAx, sprintf('Holding Current  (%.1f pA)', hold_val));
                    else
                        title(obj.holdAx, 'Holding Current');
                    end
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

end
