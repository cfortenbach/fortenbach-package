classdef CfPatchScopeTest < fortenbachlab.protocols.FortenbachLabProtocol
    % Oscilloscope-speed real-time seal / leak monitor.
    %
    % Sends a repeating rectangular pulse to the amplifier and displays the
    % response trace plus membrane resistance at ~30 Hz — fast enough to
    % rival a bench oscilloscope.
    %
    % Architecture
    % ------------
    % Each epoch is a single pulse cycle (preTime + stimTime + tailTime).
    % Epochs run continuously until the user presses Stop.  A MATLAB timer
    % drives the display at the selected refresh rate, reading from a
    % cached copy of the most-recent epoch's response.  The epoch-
    % completion callback (completeEpoch) does NO rendering — it only
    % copies the response into a cache variable.  This fully decouples
    % data acquisition from graphics, keeping the epoch pipeline fast and
    % the display smooth.

    properties
        amp                             % Output amplifier
        mode = 'seal'                   % Current mode (seal or leak)
        alternateMode = true            % Alternate mode on each successive run
        preTime = 15                    % Pulse leading duration (ms)
        stimTime = 30                   % Pulse duration (ms)
        tailTime = 15                   % Pulse trailing duration (ms)
        pulseAmplitude = 10             % Pulse amplitude (mV or pA depending on amp mode)
        leakAmpHoldSignal = -60         % Amplifier hold signal in leak mode (mV or pA)
        refreshRate = 30                % Display update rate (Hz)
    end

    properties (Hidden, Dependent)
        ampHoldSignal                   % Amplifier hold signal (mV or pA)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Hidden)
        ampType
        modeType = symphonyui.core.PropertyType('char', 'row', {'seal', 'leak'})
        scopeFigure
        scopeTimer
        latestCycleData                 % Most recent epoch response (double[])
        latestCycleUnits                % Units string for the response
        maxInFlight = 20                % Max epochs in DAQ queue
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
                s = obj.createAmpStimulus();
            end
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Clean up any leftover timer from a previous run.
            obj.stopScopeTimer();
            obj.latestCycleData  = [];
            obj.latestCycleUnits = '';

            % Remove any previous scope figure.  Use delete() — NOT close() —
            % to bypass the figure's CloseRequestFcn, which would trigger a
            % re-entrant cascade through Symphony's FigureHandlerManager
            % (FigureHandler.close → notify Closed → delete handler →
            % Protocol.delete → closeFigures → close on deleted handler).
            if ~isempty(obj.scopeFigure) && isvalid(obj.scopeFigure)
                try
                    fh = obj.scopeFigure.getFigureHandle();
                    if isvalid(fh)
                        set(fh, 'CloseRequestFcn', '');
                        delete(fh);
                    end
                catch
                end
                obj.scopeFigure = [];
            end

            % --- Build figure: response axes on top, info strip on bottom ---
            obj.scopeFigure = obj.showFigure( ...
                'symphonyui.builtin.figures.CustomFigure', @obj.handleEpochNoop);
            f = obj.scopeFigure.getFigureHandle();
            set(f, 'Name', ['Scope - ' obj.mode]);

            % Override CloseRequestFcn so that if the user clicks X during
            % a run, we stop the timer and delete the figure cleanly
            % without triggering Symphony's re-entrant close cascade.
            set(f, 'CloseRequestFcn', @(src, ~) obj.safeFigureClose(src));

            fPos  = get(f, 'Position');
            infoH = 96;    % fixed-height info strip at bottom (px)
            topPad = 40;   % room for axes title at top (px)

            % Response axes (fills space above info strip).
            obj.scopeFigure.userData.ax = axes( ...
                'Parent', f, ...
                'Units', 'normalized', ...
                'Position', [0.08  (infoH + 10) / fPos(4) ...
                             0.88  1 - (infoH + 10 + topPad) / fPos(4)]);
            xlabel(obj.scopeFigure.userData.ax, 'Time (ms)');
            ylabel(obj.scopeFigure.userData.ax, ...
                obj.rig.getDevice(obj.amp).background.displayUnits);
            title(obj.scopeFigure.userData.ax, [obj.mode ' - Scope']);

            % Info panel: mode label + resistance readout.
            obj.scopeFigure.userData.modeText = uicontrol(f, ...
                'Style', 'text', ...
                'Units', 'pixels', ...
                'Position', [10  54  fPos(3)-20  36], ...
                'FontSize', 24, ...
                'HorizontalAlignment', 'center', ...
                'String', [obj.mode ' running...']);
            obj.scopeFigure.userData.resistanceText = uicontrol(f, ...
                'Style', 'text', ...
                'Units', 'pixels', ...
                'Position', [10  4  fPos(3)-20  48], ...
                'FontSize', 36, ...
                'HorizontalAlignment', 'center', ...
                'String', 'R = ...');

            % Keep layout stable on window resize.
            ud = obj.scopeFigure.userData;
            set(f, 'SizeChangedFcn', @(src, ~) resizeLayout(src, ud, infoH, topPad));
            function resizeLayout(fig, ud, ih, tp)
                p = get(fig, 'Position');
                w = p(3); h = p(4);
                set(ud.ax, 'Position', ...
                    [0.08  (ih + 10) / h  0.88  1 - (ih + 10 + tp) / h]);
                set(ud.modeText,       'Position', [10  54  w-20  36]);
                set(ud.resistanceText,  'Position', [10   4  w-20  48]);
            end

            % --- Start the display timer ---
            period = max(0.020, round(1 / obj.refreshRate * 1000) / 1000);
            obj.scopeTimer = timer( ...
                'ExecutionMode', 'fixedRate', ...
                'Period', period, ...
                'BusyMode', 'drop', ...
                'TimerFcn', @(~, ~) obj.scopeUpdate());
            start(obj.scopeTimer);
        end

        function handleEpochNoop(~, ~, ~)
            % No-op: all display is driven by the MATLAB timer, not by
            % Symphony's epoch-completion figure-handler callbacks.
        end

        function stim = createAmpStimulus(obj)
            gen = symphonyui.builtin.stimuli.PulseGenerator();

            gen.preTime    = obj.preTime;
            gen.stimTime   = obj.stimTime;
            gen.tailTime   = obj.tailTime;
            gen.amplitude  = obj.pulseAmplitude;
            gen.mean       = obj.ampHoldSignal;
            gen.sampleRate = obj.sampleRate;
            gen.units      = obj.rig.getDevice(obj.amp).background.displayUnits;

            stim = gen.generate();
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            device = obj.rig.getDevice(obj.amp);
            epoch.addStimulus(device, obj.createAmpStimulus());
            epoch.addResponse(device);

            % Set device background to the hold signal so the amplifier
            % returns to the correct level when the protocol stops.
            device.background = symphonyui.core.Measurement( ...
                obj.ampHoldSignal, device.background.displayUnits);
        end

        % ================================================================
        %  EPOCH COMPLETION — cache data only, NO rendering.
        %  This keeps the epoch pipeline fast so the next epoch can start
        %  with minimal delay.
        % ================================================================
        function completeEpoch(obj, epoch)
            try
                device   = obj.rig.getDevice(obj.amp);
                response = epoch.getResponse(device);
                if ~isempty(response)
                    [q, u] = response.getData();
                    if ~isempty(q)
                        obj.latestCycleData  = q;
                        obj.latestCycleUnits = u;
                    end
                end
            catch
            end
            completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
        end

        % ================================================================
        %  TIMER CALLBACK — runs at ~refreshRate Hz, reads the cached
        %  response and updates the figure.
        % ================================================================
        function scopeUpdate(obj)
            try
                % --- Guards: everything still alive? ---
                if isempty(obj.scopeFigure) || ~isvalid(obj.scopeFigure)
                    return;
                end
                fh = obj.scopeFigure.getFigureHandle();
                if ~isvalid(fh), return; end
                if isempty(obj.latestCycleData), return; end

                oneCycle = obj.latestCycleData;
                units    = obj.latestCycleUnits;

                sr       = obj.sampleRate;
                prePts   = round(obj.preTime  / 1e3 * sr);
                stimPts  = round(obj.stimTime / 1e3 * sr);
                nPts     = numel(oneCycle);

                % --- Resistance calculation (every update — it's cheap) ---
                rStr = 'R = ...';
                if prePts >= 2 && stimPts >= 2 && nPts >= prePts + stimPts
                    baseline    = mean(oneCycle(1:prePts));
                    ssStart     = prePts + round(stimPts * 0.5);
                    ssEnd       = prePts + stimPts;
                    steadyState = mean(oneCycle(ssStart:ssEnd));
                    deflection  = steadyState - baseline;

                    if abs(deflection) > 0
                        % getData() returns base-SI (Amps); command is mV.
                        R_ohm  = (obj.pulseAmplitude * 1e-3) / deflection;
                        R_mohm = abs(R_ohm) / 1e6;

                        ohm = char(937);   % Unicode Ω
                        if R_mohm >= 1000
                            rStr = sprintf('R = %.2f G%s', R_mohm / 1000, ohm);
                        else
                            rStr = sprintf('R = %.1f M%s', R_mohm, ohm);
                        end
                    else
                        rStr = ['R = ' char(8734)];   % ∞
                    end
                end

                ud = obj.scopeFigure.userData;
                set(ud.resistanceText, 'String', rStr);

                % --- Auto-scale and update the trace ---
                [scaled, sUnits] = obj.siAutoScale(oneCycle, units);
                tMs = (0:nPts - 1) / sr * 1e3;
                ax  = ud.ax;

                if isfield(ud, 'line') && isvalid(ud.line)
                    set(ud.line, 'XData', tMs, 'YData', scaled);
                else
                    ud.line = line(tMs, scaled, 'Parent', ax, ...
                        'Color', [0 0.4470 0.7410]);
                    obj.scopeFigure.userData = ud;
                end

                % Padded y-axis with short history for stability.
                histLen  = 30;   % ~1 second of history at 30 Hz
                epochMin = min(scaled);
                epochMax = max(scaled);
                if ~isfield(ud, 'yHistory')
                    ud.yHistory = zeros(0, 2);
                end
                ud.yHistory(end + 1, :) = [epochMin  epochMax];
                if size(ud.yHistory, 1) > histLen
                    ud.yHistory(1, :) = [];
                end
                obj.scopeFigure.userData = ud;

                yLo  = min(ud.yHistory(:, 1));
                yHi  = max(ud.yHistory(:, 2));
                span = yHi - yLo;
                if span == 0, span = abs(yHi) * 0.1; end
                if span == 0, span = 1; end
                pad = span * 0.10;
                set(ax, 'YLim', [yLo - pad,  yHi + pad]);
                set(ax, 'XLim', [0  tMs(end)]);
                ylabel(ax, sUnits, 'Interpreter', 'none');

                % Throttle rendering: ~20 fps max so the DAQ thread is
                % never starved by graphics.
                drawnow('limitrate');

            catch
                % Silently swallow errors so the timer keeps running.
            end
        end

        % ================================================================
        %  EPOCH LIFECYCLE
        % ================================================================

        function tf = shouldContinuePreloadingEpochs(obj)
            % Limit initial preload to maxInFlight epochs so the DAQ queue
            % stays small.  A smaller queue means Stop takes effect almost
            % instantly instead of waiting for hundreds of queued epochs to
            % drain.
            inflight = obj.numEpochsPrepared - obj.numEpochsCompleted;
            tf = inflight < obj.maxInFlight;
        end

        function tf = shouldContinuePreparingEpochs(~) %#ok<MANU>
            tf = true;   % Run continuously until the user presses Stop.
        end

        function tf = shouldWaitToContinuePreparingEpochs(obj)
            % Pause epoch preparation when the in-flight limit is reached.
            inflight = obj.numEpochsPrepared - obj.numEpochsCompleted;
            tf = inflight >= obj.maxInFlight;
        end

        function tf = shouldContinueRun(~) %#ok<MANU>
            tf = true;
        end

        function completeRun(obj)
            obj.stopScopeTimer();
            obj.latestCycleData  = [];
            obj.latestCycleUnits = '';

            completeRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            if obj.alternateMode
                if strcmpi(obj.mode, 'seal')
                    obj.mode = 'leak';
                else
                    obj.mode = 'seal';
                end
            end

            if ~isempty(obj.scopeFigure) && isvalid(obj.scopeFigure) ...
                    && isstruct(obj.scopeFigure.userData) ...
                    && isfield(obj.scopeFigure.userData, 'modeText')
                set(obj.scopeFigure.userData.modeText, 'String', [obj.mode ' next']);
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

    % ====================================================================
    %  PRIVATE HELPERS
    % ====================================================================
    methods (Access = private)

        function stopScopeTimer(obj)
            if ~isempty(obj.scopeTimer)
                try stop(obj.scopeTimer);   catch, end
                try delete(obj.scopeTimer); catch, end
                obj.scopeTimer = [];
            end
        end

        function safeFigureClose(obj, figHandle)
            % Called when the user clicks X on the scope figure.  Stops the
            % timer and deletes the figure directly (bypasses Symphony's
            % CloseRequestFcn cascade that causes re-entrancy errors).
            obj.stopScopeTimer();
            obj.scopeFigure = [];
            try
                set(figHandle, 'CloseRequestFcn', '');
                delete(figHandle);
            catch
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
            scaledData  = data;
            scaledUnits = units;
            if isempty(data), return; end
            peak = max(abs(data(:)));
            if peak == 0 || ~isfinite(peak), return; end
            if isempty(units), units = ''; end

            % Strip existing SI prefix to recover the base unit.
            siPrefixes = {'p', 'n', char(181), 'u', 'm', 'k', 'M', 'G', 'T'};
            baseUnit = units;
            if numel(units) >= 2 && any(strcmp(units(1), siPrefixes))
                baseUnit = units(2:end);
            end

            % If values are already in a comfortable range, keep as-is
            % but label with the base unit (no misleading prefix).
            if peak >= 0.1 && peak < 1e4
                scaledData  = data;
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
