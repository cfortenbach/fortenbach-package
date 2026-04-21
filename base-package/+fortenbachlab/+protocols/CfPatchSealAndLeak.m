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

            layout = uix.VBox('Parent', f);

            % Response axes (top).
            obj.modeFigure.userData.ax = axes('Parent', layout);
            xlabel(obj.modeFigure.userData.ax, 'Time (ms)');
            ylabel(obj.modeFigure.userData.ax, obj.rig.getDevice(obj.amp).background.displayUnits);
            title(obj.modeFigure.userData.ax, [obj.mode ' - Response']);

            % Info panel (bottom).
            infoPanel = uix.VBox('Parent', layout);
            obj.modeFigure.userData.modeText = uicontrol( ...
                'Parent', infoPanel, ...
                'Style', 'text', ...
                'FontSize', 24, ...
                'HorizontalAlignment', 'center', ...
                'String', [obj.mode ' running...']);
            obj.modeFigure.userData.resistanceText = uicontrol( ...
                'Parent', infoPanel, ...
                'Style', 'text', ...
                'FontSize', 36, ...
                'HorizontalAlignment', 'center', ...
                'String', 'R = ...');
            set(infoPanel, 'Height', [42 54]);
            set(layout, 'Height', [-1 96]);
        end

        function updateFigure(obj, figureHandler, epoch)
            % Called automatically after each epoch completes.
            % Updates the response trace and computes membrane resistance.
            try
                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, ~] = responseData.getData();

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
                % a single noisy epoch doesn't cause jitter.  Limits are
                % rounded outward to the nearest 100 pA with 100 pA pad.
                histLen = 10;  % number of epochs to consider
                epochMin = min(quantities);
                epochMax = max(quantities);
                if ~isfield(figureHandler.userData, 'yHistory')
                    figureHandler.userData.yHistory = zeros(0, 2);
                end
                figureHandler.userData.yHistory(end+1, :) = [epochMin epochMax];
                if size(figureHandler.userData.yHistory, 1) > histLen
                    figureHandler.userData.yHistory(1, :) = [];
                end
                yMin = floor(min(figureHandler.userData.yHistory(:,1)) / 100) * 100 - 100;
                yMax = ceil(max(figureHandler.userData.yHistory(:,2)) / 100) * 100 + 100;
                if yMin == yMax
                    yMin = yMin - 100;
                    yMax = yMax + 100;
                end
                set(ax, 'YLim', [yMin yMax]);
                set(ax, 'XLim', [0 tMs(end)]);

                % --- Compute resistance ---
                if prePts >= 2 && stimPts >= 2 && nPts >= prePts + stimPts
                    baseline    = mean(quantities(1:prePts));
                    ssStart     = prePts + round(stimPts * 0.5);
                    ssEnd       = prePts + stimPts;
                    steadyState = mean(quantities(ssStart:ssEnd));
                    deflection  = steadyState - baseline;

                    if abs(deflection) > 0
                        % V-clamp: command mV, response pA -> mV/pA = GOhm.
                        rGOhm = obj.pulseAmplitude / deflection;
                        rMOhm = abs(rGOhm) * 1000;

                        if rMOhm >= 1000
                            rStr = sprintf('R = %.2f G\\Omega', rMOhm / 1000);
                        else
                            rStr = sprintf('R = %.1f M\\Omega', rMOhm);
                        end
                    else
                        rStr = 'R = \infty';
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

            if isvalid(obj.modeFigure)
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

end
