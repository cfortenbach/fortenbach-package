classdef CfPatchMeasureVrest < fortenbachlab.protocols.FortenbachLabProtocol
    % Measures resting membrane potential (Vrest) in I=0 mode.
    %
    % Workflow:
    %   1. Go whole-cell.
    %   2. Switch to I=0 in MultiClamp Commander.
    %   3. Run this protocol — it records for recordTime ms, computes Vrest,
    %      saves it as an epoch parameter and epoch block property, and
    %      displays the result.
    %   4. Switch back to V-Clamp in MultiClamp Commander.
    %   5. The protocol detects the mode change and stops automatically.
    %
    % Vrest is saved as:
    %   - Epoch parameter:       'restingMembranePotential_mV'
    %   - Epoch block property:  'restingMembranePotential_mV'  (visible to
    %     all subsequent protocols in this cell)

    properties
        amp                             % Input amplifier
        recordTime = 500                % Recording duration (ms)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Hidden)
        ampType
        vrestFigure
        measuredVrest
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
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            obj.measuredVrest = NaN;

            % Detect current amplifier mode via telegraph.
            device = obj.rig.getDevice(obj.amp);
            try
                obj.modeAtStart = device.getMode();
            catch
                obj.modeAtStart = 'unknown';
            end

            if ~strcmp(obj.modeAtStart, 'I0')
                warning('CfPatchMeasureVrest:NotI0', ...
                    ['Amplifier is in %s mode. Switch to I=0 in MultiClamp ' ...
                     'Commander for an accurate Vrest measurement.'], obj.modeAtStart);
            end

            % Show a figure with the recorded trace and Vrest readout.
            % Plain pixel positioning (no uix.VBox).
            obj.vrestFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.updateFigure);
            f = obj.vrestFigure.getFigureHandle();
            set(f, 'Name', 'Resting Membrane Potential');

            fPos = get(f, 'Position');
            infoH = 106; topPad = 40;

            % Trace axes (top portion).
            obj.vrestFigure.userData.ax = axes('Parent', f, ...
                'Units', 'normalized', ...
                'Position', [0.10  (infoH + 10)/fPos(4)  0.85  1 - (infoH + 10 + topPad)/fPos(4)]);
            xlabel(obj.vrestFigure.userData.ax, 'Time (ms)');
            ylabel(obj.vrestFigure.userData.ax, 'mV');
            title(obj.vrestFigure.userData.ax, 'Vrest Recording');
            grid(obj.vrestFigure.userData.ax, 'on');

            % Info panel (bottom strip): mode, Vrest readout, instruction.
            obj.vrestFigure.userData.modeText = uicontrol(f, ...
                'Style', 'text', ...
                'Units', 'pixels', ...
                'Position', [10 78 fPos(3)-20 24], ...
                'FontSize', 16, ...
                'HorizontalAlignment', 'center', ...
                'String', sprintf('Mode: %s', obj.modeAtStart));
            obj.vrestFigure.userData.vrestText = uicontrol(f, ...
                'Style', 'text', ...
                'Units', 'pixels', ...
                'Position', [10 26 fPos(3)-20 50], ...
                'FontSize', 36, ...
                'HorizontalAlignment', 'center', ...
                'String', 'Vrest = ...');
            obj.vrestFigure.userData.instructionText = uicontrol(f, ...
                'Style', 'text', ...
                'Units', 'pixels', ...
                'Position', [10 4 fPos(3)-20 20], ...
                'FontSize', 12, ...
                'ForegroundColor', [0.6 0.6 0.6], ...
                'HorizontalAlignment', 'center', ...
                'String', 'Switch back to V-Clamp in Commander when done.');

            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
        end

        function updateFigure(obj, figureHandler, epoch)
            try
                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, units] = responseData.getData();
                try
                    [fullQ, fullU] = responseData.getFullData();
                    if ~isempty(fullQ), quantities = fullQ; units = fullU; end
                catch
                end
                [quantities, units] = obj.siAutoScale(quantities, units);
                sr = responseData.sampleRate.quantityInBaseUnits;

                ax = figureHandler.userData.ax;
                tMs = (0:numel(quantities)-1) / sr * 1e3;
                cla(ax);
                plot(ax, tMs, quantities, 'Color', [0 0.45 0.74], 'LineWidth', 1);
                xlabel(ax, 'Time (ms)');
                ylabel(ax, units, 'Interpreter', 'none');
                grid(ax, 'on');

                % Skip the first 50 ms to allow any settling, then average.
                skipPts = round(0.050 * sr);  % 50 ms
                if skipPts < numel(quantities)
                    vrest = mean(quantities(skipPts+1:end));
                else
                    vrest = mean(quantities);
                end
                obj.measuredVrest = vrest;

                % Draw Vrest as a horizontal line.
                hold(ax, 'on');
                plot(ax, [tMs(1) tMs(end)], [vrest vrest], '--', ...
                    'Color', [0.85 0.33 0.10], 'LineWidth', 1.5);
                hold(ax, 'off');
                title(ax, sprintf('Vrest Recording  (%.1f %s)', vrest, units));

                set(figureHandler.userData.vrestText, 'String', ...
                    sprintf('Vrest = %.1f %s', vrest, units));
            catch ME
                fprintf(2, '[MeasureVrest] Figure update error: %s\n', ME.message);
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

            % Compute Vrest from the response.
            try
                responseData = epoch.getResponse(obj.rig.getDevice(obj.amp));
                [quantities, ~] = responseData.getData();
                sr = obj.sampleRate;

                % Skip first 50 ms for settling.
                skipPts = round(0.050 * sr);
                if skipPts < numel(quantities)
                    vrest = mean(quantities(skipPts+1:end));
                else
                    vrest = mean(quantities);
                end
                obj.measuredVrest = vrest;

                % Save to epoch.
                epoch.addParameter('restingMembranePotential_mV', vrest);

                % Save to epoch block so it persists for subsequent protocols.
                try
                    eb = obj.persistor.currentEpochBlock;
                    if ~isempty(eb)
                        eb.setProperty('restingMembranePotential_mV', vrest);
                    end
                catch
                end

                fprintf('[MeasureVrest] Vrest = %.1f mV\n', vrest);
            catch ME
                fprintf(2, '[MeasureVrest] Error computing Vrest: %s\n', ME.message);
            end
        end

        function completeRun(obj)
            completeRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            if isfinite(obj.measuredVrest)
                fprintf('[MeasureVrest] Final Vrest = %.1f mV. Switch back to V-Clamp in Commander.\n', ...
                    obj.measuredVrest);
            end
        end

        function tf = shouldContinuePreparingEpochs(obj) %#ok<MANU>
            % Single epoch only.
            tf = obj.numEpochsPrepared < 1;
        end

        function tf = shouldContinueRun(obj) %#ok<MANU>
            tf = obj.numEpochsCompleted < 1;
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
