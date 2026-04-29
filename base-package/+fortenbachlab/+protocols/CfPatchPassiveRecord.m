classdef CfPatchPassiveRecord < fortenbachlab.protocols.FortenbachLabProtocol
    % Passively records membrane potential in I=0 mode.
    %
    % Runs continuously (repeating epochs of recordTime ms) until stopped.
    % Each epoch computes and displays the mean Vm. A running Vrest trend
    % is shown across epochs so you can monitor stability.
    %
    % Optional: enable showPowerSpectrum to display a running-average
    % Fourier analysis of the recorded signal (1–80 Hz by default).
    %
    % Workflow:
    %   1. Go whole-cell.
    %   2. Switch to I=0 in MultiClamp Commander.
    %   3. Run this protocol — it records continuously and shows Vm.
    %   4. Press Stop when done, then switch back to V-Clamp.

    properties
        amp                             % Input amplifier
        recordTime = 1000               % Epoch duration (ms)
        showPowerSpectrum = false        % Show running-average FFT figure
        fftLow = 1                      % Power spectrum lower bound (Hz)
        fftHigh = 80                    % Power spectrum upper bound (Hz)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Hidden)
        ampType
        vmFigure
        modeAtStart
    end

    methods

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.FortenbachLabProtocol(obj, name);
            if strncmp(name, 'amp2', 4) && numel(obj.rig.getDeviceNames('Amp')) < 2
                d.isHidden = true;
            end

            % Hide FFT range fields when power spectrum is off.
            if (strcmp(name, 'fftLow') || strcmp(name, 'fftHigh')) && ~obj.showPowerSpectrum
                d.isHidden = true;
            end
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Detect amplifier mode.
            device = obj.rig.getDevice(obj.amp);
            try
                obj.modeAtStart = device.getMode();
            catch
                obj.modeAtStart = 'unknown';
            end

            if ~strcmp(obj.modeAtStart, 'I0')
                warning('CfPatchPassiveRecord:NotI0', ...
                    ['Amplifier is in %s mode. Switch to I=0 in MultiClamp ' ...
                     'Commander for passive Vm recording.'], obj.modeAtStart);
            end

            % Custom figure: Vm trace on top, Vrest trend on bottom.
            obj.vmFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.updateFigure);
            f = obj.vmFigure.getFigureHandle();
            set(f, 'Name', 'Passive Recording');

            layout = uix.VBox('Parent', f);

            % Vm trace axes (top).
            obj.vmFigure.userData.traceAx = axes('Parent', layout);
            xlabel(obj.vmFigure.userData.traceAx, 'Time (ms)');
            ylabel(obj.vmFigure.userData.traceAx, 'Membrane Potential (mV)');
            title(obj.vmFigure.userData.traceAx, 'Vm');
            grid(obj.vmFigure.userData.traceAx, 'on');

            % Vrest trend axes (bottom).
            obj.vmFigure.userData.trendAx = axes('Parent', layout);
            xlabel(obj.vmFigure.userData.trendAx, 'Epoch');
            ylabel(obj.vmFigure.userData.trendAx, 'V_{rest} (mV)');
            title(obj.vmFigure.userData.trendAx, 'Vrest Trend');
            grid(obj.vmFigure.userData.trendAx, 'on');

            % Vrest readout text.
            obj.vmFigure.userData.vrestText = uicontrol( ...
                'Parent', layout, ...
                'Style', 'text', ...
                'FontSize', 28, ...
                'HorizontalAlignment', 'center', ...
                'String', 'Vrest = ...');

            set(layout, 'Heights', [-2 -1 44]);

            % Storage for trend data.
            obj.vmFigure.userData.vrestHistory = [];

            % Standard response figure.
            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));

            % Optional power spectrum figure.
            if obj.showPowerSpectrum
                obj.showFigure('fortenbachlab.figures.PowerSpectrumFigure', ...
                    obj.rig.getDevice(obj.amp), ...
                    'freqRange', [obj.fftLow obj.fftHigh]);
            end
        end

        function updateFigure(obj, figureHandler, epoch)
            try
                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, ~] = responseData.getData();
                sr = responseData.sampleRate.quantityInBaseUnits;

                % --- Vm trace ---
                ax = figureHandler.userData.traceAx;
                tMs = (0:numel(quantities)-1) / sr * 1e3;
                cla(ax);
                plot(ax, tMs, quantities, 'Color', [0 0.45 0.74], 'LineWidth', 0.8);
                xlabel(ax, 'Time (ms)');
                ylabel(ax, 'Membrane Potential (mV)');
                grid(ax, 'on');

                % Compute Vrest: skip first 50 ms for settling, then average.
                skipPts = round(0.050 * sr);
                if skipPts < numel(quantities)
                    vrest = mean(quantities(skipPts+1:end));
                else
                    vrest = mean(quantities);
                end

                % Draw Vrest line on trace.
                hold(ax, 'on');
                plot(ax, [tMs(1) tMs(end)], [vrest vrest], '--', ...
                    'Color', [0.85 0.33 0.10], 'LineWidth', 1.5);
                hold(ax, 'off');
                title(ax, sprintf('Vm  (mean = %.1f mV)', vrest));

                % Update readout.
                set(figureHandler.userData.vrestText, 'String', ...
                    sprintf('V_{rest} = %.1f mV', vrest));

                % --- Vrest trend ---
                figureHandler.userData.vrestHistory(end+1) = vrest;
                history = figureHandler.userData.vrestHistory;
                trendAx = figureHandler.userData.trendAx;
                cla(trendAx);
                epochs = 1:numel(history);
                plot(trendAx, epochs, history, 'o-', ...
                    'Color', [0.47 0.67 0.19], ...
                    'MarkerFaceColor', [0.47 0.67 0.19], 'MarkerSize', 4);
                xlabel(trendAx, 'Epoch');
                ylabel(trendAx, 'V_{rest} (mV)');
                title(trendAx, sprintf('Vrest Trend  (n = %d)', numel(history)));
                grid(trendAx, 'on');

            catch ME
                fprintf(2, '[PassiveRecord] Figure update error: %s\n', ME.message);
            end
        end

        function stim = createAmpStimulus(obj)
            % Flat stimulus at the amp background (0 pA in I=0 mode).
            device = obj.rig.getDevice(obj.amp);
            bg = device.background.quantity;
            units = device.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            totalPts = timeToPts(obj.recordTime);
            data = ones(1, totalPts) * bg;
            stim = obj.createStimulusFromArray(data, units);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpStimulus());
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function completeEpoch(obj, epoch)
            completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            % Save Vrest to epoch parameters.
            try
                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, ~] = responseData.getData();
                sr = obj.sampleRate;

                skipPts = round(0.050 * sr);
                if skipPts < numel(quantities)
                    vrest = mean(quantities(skipPts+1:end));
                else
                    vrest = mean(quantities);
                end

                epoch.addParameter('meanVm_mV', vrest);
            catch
            end
        end

        function tf = shouldContinuePreparingEpochs(obj) %#ok<MANU>
            % Run continuously until stopped.
            tf = true;
        end

        function tf = shouldContinueRun(obj) %#ok<MANU>
            tf = true;
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
