classdef CfPatchSealAndLeak < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents rectangular pulse stimuli to a specified amplifier while
    % recording the response.  A real-time trace is displayed and the
    % membrane resistance is calculated and shown after every epoch.

    properties
        amp                             % Output amplifier
        mode = 'seal'                   % Current mode of protocol
        alternateMode = true            % Alternate from seal to leak to seal etc., on each successive run
        preTime = 10                    % Pulse leading duration (ms)
        stimTime = 20                   % Pulse duration (ms)
        tailTime = 10                   % Pulse trailing duration (ms)
        pulseAmplitude = 10             % Pulse amplitude (mV or pA depending on amp mode)
        leakAmpHoldSignal = -60         % Amplifier hold signal to use while in leak mode (mV or pA depending on amp mode)
    end

    properties (Hidden, Dependent)
        ampHoldSignal                   % Amplifier hold signal (mV or pA depending on amp mode)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Hidden)
        ampType
        modeType = symphonyui.core.PropertyType('char', 'row', {'seal', 'leak'})
        modeFigure
    end

    methods

        function s = get.ampHoldSignal(obj)
            if strcmpi(obj.mode, 'seal')
                s = 0;
            else
                s = obj.leakAmpHoldSignal;
            end
        end

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.FortenbachLabProtocol(obj, name);

            if strncmp(name, 'amp2', 4) && numel(obj.rig.getDeviceNames('Amp')) < 2
                d.isHidden = true;
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()createPreviewStimuli(obj));
            function s = createPreviewStimuli(obj)
                gen = symphonyui.builtin.stimuli.PulseGenerator();
                gen.preTime = obj.preTime;
                gen.stimTime = obj.stimTime;
                gen.tailTime = obj.tailTime;
                gen.amplitude = obj.pulseAmplitude;
                gen.mean = obj.ampHoldSignal;
                gen.sampleRate = obj.sampleRate;
                gen.units = obj.rig.getDevice(obj.amp).background.displayUnits;
                s = gen.generate();
            end
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Close any existing figure so we get a fresh one each run.
            if ~isempty(obj.modeFigure) && isvalid(obj.modeFigure)
                try
                    close(obj.modeFigure.getFigureHandle());
                catch
                end
                obj.modeFigure = [];
            end

            % Combined figure: response trace on top, mode + resistance below.
            obj.modeFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.updateFigure);
            f = obj.modeFigure.getFigureHandle();
            set(f, 'Name', ['Seal & Leak - ' obj.mode]);

            % Use manual positioning instead of uix.VBox (unavailable in
            % Symphony 3).  Info panel is a fixed 96 px strip at the
            % bottom; the axes fill the rest.
            fPos = get(f, 'Position');
            infoH = 96;

            % Response axes (top portion).  Leave 40 px at the top for
            % the title so it isn't clipped.
            topPad = 40;
            obj.modeFigure.userData.ax = axes( ...
                'Parent', f, ...
                'Units', 'normalized', ...
                'Position', [0.08 (infoH + 10) / fPos(4) 0.88 1 - (infoH + 10 + topPad) / fPos(4)]);
            xlabel(obj.modeFigure.userData.ax, 'Time (ms)');
            ylabel(obj.modeFigure.userData.ax, obj.rig.getDevice(obj.amp).background.displayUnits);
            title(obj.modeFigure.userData.ax, [obj.mode ' - Response']);

            % Info panel (bottom strip): mode label + resistance readout.
            obj.modeFigure.userData.modeText = uicontrol(f, ...
                'Style', 'text', ...
                'Units', 'pixels', ...
                'Position', [10 54 fPos(3)-20 36], ...
                'FontSize', 24, ...
                'HorizontalAlignment', 'center', ...
                'String', [obj.mode ' running...']);
            obj.modeFigure.userData.resistanceText = uicontrol(f, ...
                'Style', 'text', ...
                'Units', 'pixels', ...
                'Position', [10 4 fPos(3)-20 48], ...
                'FontSize', 36, ...
                'HorizontalAlignment', 'center', ...
                'String', 'R = ...');

            % Keep layout stable on resize.
            ud = obj.modeFigure.userData;
            set(f, 'SizeChangedFcn', @(src,~) resizeLayout(src, ud, infoH, topPad));
            function resizeLayout(fig, ud, infoH, topPad)
                p = get(fig, 'Position');
                w = p(3); h = p(4);
                % Axes: recalculate position with room for title at top
                set(ud.ax, 'Position', ...
                    [0.08 (infoH + 10) / h  0.88  1 - (infoH + 10 + topPad) / h]);
                % Info text controls: stretch width
                set(ud.modeText, 'Position', [10 54 w-20 36]);
                set(ud.resistanceText, 'Position', [10 4 w-20 48]);
            end
        end

        function updateFigure(obj, figureHandler, epoch)
            % Called automatically after each epoch completes.
            % Updates the response trace and computes membrane resistance.
            try
                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, units] = responseData.getData();
                % Use getFullData() for completed epochs to get all
                % accumulated samples, not just the streaming window.
                try
                    [fullQ, fullU] = responseData.getFullData();
                    if ~isempty(fullQ)
                        quantities = fullQ;
                        units = fullU;
                    end
                catch
                end

                % Keep raw values (base SI) for the resistance calc.
                rawQuantities = quantities;

                % Auto-scale for display (A → nA, pA, etc.)
                [quantities, units] = obj.siAutoScale(quantities, units);

                sr = obj.sampleRate;
                prePts  = round(obj.preTime  / 1e3 * sr);
                stimPts = round(obj.stimTime / 1e3 * sr);
                nPts    = numel(quantities);

                % --- Update response trace ---
                ax = figureHandler.userData.ax;
                tMs = (0:nPts-1) / sr * 1e3;  % time in ms
                if isfield(figureHandler.userData, 'line') && isvalid(figureHandler.userData.line)
                    set(figureHandler.userData.line, 'XData', tMs, 'YData', quantities);
                else
                    figureHandler.userData.line = line(tMs, quantities, 'Parent', ax, 'Color', [0 0.4470 0.7410]);
                end

                % Padded y-axis: track min/max over the last N epochs so
                % a single noisy epoch doesn't cause jitter.  Pad by 10%
                % of the data range (adapts to any signal amplitude).
                histLen = 10;
                epochMin = min(quantities);
                epochMax = max(quantities);
                if ~isfield(figureHandler.userData, 'yHistory')
                    figureHandler.userData.yHistory = zeros(0, 2);
                end
                figureHandler.userData.yHistory(end+1, :) = [epochMin epochMax];
                if size(figureHandler.userData.yHistory, 1) > histLen
                    figureHandler.userData.yHistory(1, :) = [];
                end
                yLo = min(figureHandler.userData.yHistory(:,1));
                yHi = max(figureHandler.userData.yHistory(:,2));
                span = yHi - yLo;
                if span == 0, span = abs(yHi) * 0.1; end
                if span == 0, span = 1; end
                pad = span * 0.10;
                yMin = yLo - pad;
                yMax = yHi + pad;
                set(ax, 'YLim', [yMin yMax]);
                set(ax, 'XLim', [0 tMs(end)]);
                ylabel(ax, units, 'Interpreter', 'none');

                % --- Compute resistance from RAW base-unit data ---
                % getData() returns values in base SI (Amps) regardless
                % of the units string it reports.  Use Ohm's law in SI:
                %   R(Ohm) = V(Volt) / I(Amp)
                % pulseAmplitude is in mV, rawQuantities are in A.
                if prePts >= 2 && stimPts >= 2 && nPts >= prePts + stimPts
                    baseline    = mean(rawQuantities(1:prePts));
                    ssStart     = prePts + round(stimPts * 0.5);
                    ssEnd       = prePts + stimPts;
                    steadyState = mean(rawQuantities(ssStart:ssEnd));
                    deflection  = steadyState - baseline;

                    if abs(deflection) > 0
                        R_ohm = (obj.pulseAmplitude * 1e-3) / deflection;
                        R_mohm = abs(R_ohm) / 1e6;

                        ohm = char(937);  % Ω (Unicode, uicontrol has no TeX)
                        if R_mohm >= 1000
                            rStr = sprintf('R = %.2f G%s', R_mohm / 1000, ohm);
                        else
                            rStr = sprintf('R = %.1f M%s', R_mohm, ohm);
                        end
                    else
                        rStr = ['R = ' char(8734)];  % ∞
                    end
                else
                    rStr = 'R = ...';
                end
            catch
                rStr = 'R = ...';
            end

            set(figureHandler.userData.resistanceText, 'String', rStr);
        end

        function stim = createAmpStimulus(obj)
            gen = symphonyui.builtin.stimuli.PulseGenerator();

            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.amplitude = obj.pulseAmplitude;
            gen.mean = obj.ampHoldSignal;
            gen.sampleRate = obj.sampleRate;
            gen.units = obj.rig.getDevice(obj.amp).background.displayUnits;

            stim = gen.generate();
        end

        function stim = createOscilloscopeTriggerStimulus(obj)
            gen = symphonyui.builtin.stimuli.PulseGenerator();

            gen.preTime = 0;
            gen.stimTime = 1;
            gen.tailTime = obj.preTime + obj.stimTime + obj.tailTime - 1;
            gen.amplitude = 1;
            gen.mean = 0;
            gen.sampleRate = obj.sampleRate;
            gen.units = symphonyui.core.Measurement.UNITLESS;

            stim = gen.generate();
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpStimulus());
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            triggers = obj.rig.getDevices('Oscilloscope Trigger');
            if ~isempty(triggers)
                epoch.addStimulus(triggers{1}, obj.createOscilloscopeTriggerStimulus());
            end

            device = obj.rig.getDevice(obj.amp);
            device.background = symphonyui.core.Measurement(obj.ampHoldSignal, device.background.displayUnits);
        end

        function tf = shouldContinuePreparingEpochs(obj) %#ok<MANU>
            tf = true;
        end

        function tf = shouldContinueRun(obj) %#ok<MANU>
            tf = true;
        end

        function completeRun(obj)
            completeRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            if obj.alternateMode
                if strcmpi(obj.mode, 'seal')
                    obj.mode = 'leak';
                else
                    obj.mode = 'seal';
                end
            end

            if ~isempty(obj.modeFigure) && isvalid(obj.modeFigure) ...
                    && isstruct(obj.modeFigure.userData) ...
                    && isfield(obj.modeFigure.userData, 'modeText')
                set(obj.modeFigure.userData.modeText, 'String', [obj.mode ' next']);
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

    methods (Static, Access = private)
        function [scaledData, scaledUnits] = siAutoScale(data, units)
            %SIAUTOSCALE  Pick an SI prefix so axis tick labels stay readable.
            %   getData() returns numeric values in BASE SI units (e.g. Amps)
            %   but may label them with a prefixed string (e.g. 'pA').
            %   We strip any existing prefix so we always work from the
            %   base unit, then choose the right prefix for the magnitude.
            scaledData = data;
            scaledUnits = units;
            if isempty(data), return; end
            peak = max(abs(data(:)));
            if peak == 0 || ~isfinite(peak), return; end
            if isempty(units), units = ''; end

            % Strip existing SI prefix to recover the base unit.
            siPrefixes = {'p','n',char(181),'u','m','k','M','G','T'};
            baseUnit = units;
            if numel(units) >= 2 && any(strcmp(units(1), siPrefixes))
                baseUnit = units(2:end);
            end

            % If values are already in a comfortable range, keep as-is
            % but label with the base unit (no misleading prefix).
            if peak >= 0.1 && peak < 1e4
                scaledData = data;
                scaledUnits = baseUnit;
                return;
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
