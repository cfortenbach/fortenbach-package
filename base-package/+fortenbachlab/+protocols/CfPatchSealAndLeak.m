classdef CfPatchSealAndLeak < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents rectangular pulse stimuli to a specified amplifier while
    % recording the response.  A real-time trace is displayed and the
    % membrane resistance is calculated and shown continuously.
    %
    % Architecture
    % ------------
    % Each epoch is a single pulse cycle (preTime + stimTime + tailTime).
    % Epochs run continuously until the user presses Stop.  A MATLAB timer
    % drives the display at ~30 Hz, reading from a cached copy of the
    % most-recent epoch's response.  The epoch-completion callback
    % (completeEpoch) does NO rendering — it only copies the response into
    % a cache variable.  This fully decouples data acquisition from
    % graphics, keeping the epoch pipeline fast and the display smooth.
    % Without this decoupling, the rapid epoch-completion callbacks
    % (50+/sec for 20 ms epochs) build a display backlog that causes
    % stale data to keep rendering for many seconds after the user
    % presses Stop.

    properties
        amp                             % Output amplifier
        mode = 'seal'                   % Current mode of protocol
        alternateMode = true            % Alternate from seal to leak to seal etc., on each successive run
        preTime = 5                     % Pulse leading duration (ms)
        stimTime = 10                   % Pulse duration (ms)
        tailTime = 5                    % Pulse trailing duration (ms)
        pulseAmplitude = 10             % Pulse amplitude (mV or pA depending on amp mode)
        leakAmpHoldSignal = -60         % Amplifier hold signal to use while in leak mode (mV or pA depending on amp mode)
        refreshRate = 30                % Display update rate (Hz)
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
        displayTimer                    % MATLAB timer for display updates
        latestCycleData                 % Most recent epoch response (double[])
        latestCycleUnits                % Units string for the response
        maxInFlight = 20                % Max epochs in DAQ queue (~400ms for 20ms epochs)
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

            switch name
                case 'preTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Pre Time (ms)';
                case 'stimTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Stim Time (ms)';
                case 'tailTime'
                    d.category = 'Stimulus';
                    d.displayName = 'Tail Time (ms)';
                case 'leakAmpHoldSignal'
                    d.category = 'Amplifier';
                    d.displayName = 'Leak Hold Signal (mV)';
                case 'amp'
                    d.category = 'Amplifier';
                case 'amp2'
                    d.category = 'Amplifier';
                case 'numberOfAverages'
                    d.category = 'Acquisition';
                    d.displayName = 'Number of Averages';
                case 'interpulseInterval'
                    d.category = 'Acquisition';
                    d.displayName = 'Interpulse Interval (s)';
            end

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

            % Clean up any leftover timer from a previous run.
            obj.stopDisplayTimer();
            obj.latestCycleData  = [];
            obj.latestCycleUnits = '';

            % Remove any previous figure.  Use delete() — NOT close() — to
            % bypass the figure's CloseRequestFcn and avoid a re-entrant
            % cascade through Symphony's FigureHandlerManager.
            if ~isempty(obj.modeFigure) && isvalid(obj.modeFigure)
                try
                    fh = obj.modeFigure.getFigureHandle();
                    if isvalid(fh)
                        set(fh, 'CloseRequestFcn', '');
                        delete(fh);
                    end
                catch
                end
                obj.modeFigure = [];
            end

            % Combined figure: response trace on top, mode + resistance below.
            % The figure handler callback is a no-op because all display is
            % driven by the MATLAB timer (see displayUpdate).
            obj.modeFigure = obj.showFigure( ...
                'symphonyui.builtin.figures.CustomFigure', @obj.handleEpochNoop);
            f = obj.modeFigure.getFigureHandle();
            set(f, 'Name', ['Seal & Leak - ' obj.mode]);

            % Override CloseRequestFcn so that if the user clicks X during
            % a run, we stop the timer and delete the figure cleanly
            % without triggering Symphony's re-entrant close cascade.
            set(f, 'CloseRequestFcn', @(src, ~) obj.safeFigureClose(src));

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
                set(ud.ax, 'Position', ...
                    [0.08 (infoH + 10) / h  0.88  1 - (infoH + 10 + topPad) / h]);
                set(ud.modeText, 'Position', [10 54 w-20 36]);
                set(ud.resistanceText, 'Position', [10 4 w-20 48]);
            end

            % --- Start the display timer ---
            period = max(0.020, round(1 / obj.refreshRate * 1000) / 1000);
            obj.displayTimer = timer( ...
                'ExecutionMode', 'fixedRate', ...
                'Period', period, ...
                'BusyMode', 'drop', ...
                'TimerFcn', @(~, ~) obj.displayUpdate());
            start(obj.displayTimer);
        end

        function handleEpochNoop(~, ~, ~)
            % No-op: all display is driven by the MATLAB timer, not by
            % Symphony's epoch-completion figure-handler callbacks.
        end

        % ================================================================
        %  EPOCH COMPLETION — cache data only, NO rendering.
        %  This keeps the epoch pipeline fast so the next epoch can start
        %  with minimal delay.  With 20 ms epochs (~50/sec), even light
        %  rendering work in this callback builds a backlog that causes
        %  stale data to keep displaying after Stop.
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
        function displayUpdate(obj)
            try
                % --- Guards: everything still alive? ---
                if isempty(obj.modeFigure) || ~isvalid(obj.modeFigure)
                    return;
                end
                fh = obj.modeFigure.getFigureHandle();
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

                ud = obj.modeFigure.userData;
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
                    obj.modeFigure.userData = ud;
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
                obj.modeFigure.userData = ud;

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

        function tf = shouldContinuePreloadingEpochs(obj)
            % Limit initial preload to maxInFlight epochs so the DAQ queue
            % stays small.  With 20 ms epochs the default 3-second queue
            % holds ~150 epochs — far too many.  When Stop is pressed the
            % C# side must drain or discard them all, causing a visible
            % delay.  Keeping the queue short makes stop near-instant.
            inflight = obj.numEpochsPrepared - obj.numEpochsCompleted;
            tf = inflight < obj.maxInFlight;
        end

        function tf = shouldContinuePreparingEpochs(obj) %#ok<MANU>
            tf = true;
        end

        function tf = shouldWaitToContinuePreparingEpochs(obj)
            % Pause epoch preparation when the in-flight limit is reached.
            % The Controller's processLoop calls this in its inner wait
            % loop, pausing with pause(0.01) until an in-flight epoch
            % completes and inflight drops below maxInFlight.
            inflight = obj.numEpochsPrepared - obj.numEpochsCompleted;
            tf = inflight >= obj.maxInFlight;
        end

        function tf = shouldContinueRun(obj) %#ok<MANU>
            tf = true;
        end

        function completeRun(obj)
            obj.stopDisplayTimer();
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

    % ====================================================================
    %  PRIVATE HELPERS
    % ====================================================================
    methods (Access = private)

        function stopDisplayTimer(obj)
            if ~isempty(obj.displayTimer)
                try stop(obj.displayTimer);   catch, end
                try delete(obj.displayTimer); catch, end
                obj.displayTimer = [];
            end
        end

        function safeFigureClose(obj, figHandle)
            % Called when the user clicks X on the figure.  Stops the
            % timer and deletes the figure directly (bypasses Symphony's
            % CloseRequestFcn cascade that causes re-entrancy errors).
            obj.stopDisplayTimer();
            obj.modeFigure = [];
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
