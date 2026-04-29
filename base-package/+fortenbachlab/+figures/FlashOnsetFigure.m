classdef FlashOnsetFigure < symphonyui.core.FigureHandler
    % FLASHONSETFIGURE  Running-average zoomed view around stimulus onset.
    %
    %   Shows running-average response traces grouped by a specified epoch
    %   parameter (e.g. 'lightAmplitude'). Each group gets its own colour.
    %   When no groupBy key is given, all epochs are averaged together.
    %
    %   Optional: pass 'ledDevice' to overlay the LED stimulus waveform
    %   on a secondary y-axis.
    %
    %   Usage:
    %     obj.showFigure('fortenbachlab.figures.FlashOnsetFigure', ...
    %         obj.rig.getDevice(obj.amp), ...
    %         'preTime', obj.preTime, ...
    %         'prePad', 5, ...
    %         'postPad', 100, ...
    %         'groupBy', 'lightAmplitude', ...
    %         'ledDevice', obj.rig.getDevice(obj.led));

    properties (SetAccess = private)
        device
        preTime     % Protocol pre-time (ms)
        prePad      % Window before onset (ms)
        postPad     % Window after onset (ms)
        ledDevice   % Optional LED device for stimulus overlay
        groupBy     % Epoch parameter key to group by (char or empty)
    end

    properties (Access = private)
        axHandle
        epochCount
        colorOrder
        groups      % Cell array of structs: {key, sumY, count, lineHandle}
        stimLines   % Cell array of structs: {key, lineHandle} for right axis
    end

    methods

        function obj = FlashOnsetFigure(device, varargin)
            ip = inputParser();
            ip.addParameter('preTime', 0, @isnumeric);
            ip.addParameter('prePad', 5, @isnumeric);
            ip.addParameter('postPad', 100, @isnumeric);
            ip.addParameter('ledDevice', [], @(x)isempty(x) || isobject(x));
            ip.addParameter('groupBy', '', @(x)ischar(x) || isstring(x));
            ip.parse(varargin{:});

            obj.device = device;
            obj.preTime = ip.Results.preTime;
            obj.prePad = ip.Results.prePad;
            obj.postPad = ip.Results.postPad;
            obj.ledDevice = ip.Results.ledDevice;
            obj.groupBy = char(ip.Results.groupBy);

            obj.epochCount = 0;
            obj.groups = {};
            obj.stimLines = {};

            obj.colorOrder = [ ...
                0.00 0.45 0.74; ...
                0.85 0.33 0.10; ...
                0.93 0.69 0.13; ...
                0.49 0.18 0.56; ...
                0.47 0.67 0.19; ...
                0.30 0.75 0.93; ...
                0.64 0.08 0.18];

            obj.createUi();
        end

        function createUi(obj)
            set(obj.figureHandle, 'Name', 'Flash Onset');

            obj.axHandle = axes( ...
                'Parent', obj.figureHandle, ...
                'FontUnits', get(obj.figureHandle, 'DefaultUicontrolFontUnits'), ...
                'FontName', get(obj.figureHandle, 'DefaultUicontrolFontName'), ...
                'FontSize', get(obj.figureHandle, 'DefaultUicontrolFontSize'));

            if ~isempty(obj.ledDevice)
                yyaxis(obj.axHandle, 'right');
                ylabel(obj.axHandle, 'LED (V)', 'Interpreter', 'none');
                obj.axHandle.YColor = [0.85 0.33 0.10];
                yyaxis(obj.axHandle, 'left');
                obj.axHandle.YColor = [0 0.15 0.35];
            end

            xlabel(obj.axHandle, 'Time from onset (ms)');
            ylabel(obj.axHandle, 'Response');
            title(obj.axHandle, 'Flash Onset (mean)');
            grid(obj.axHandle, 'on');
            hold(obj.axHandle, 'on');

            yl = ylim(obj.axHandle);
            line(obj.axHandle, [0 0], yl, ...
                'Color', [0.6 0.6 0.6], 'LineStyle', '--', ...
                'Tag', 'onsetLine', 'HandleVisibility', 'off');
        end

        function handleEpoch(obj, epoch)
            try
                if ~epoch.hasResponse(obj.device)
                    return;
                end

                response = epoch.getResponse(obj.device);
                [quantities, ~] = response.getData();
                sr = response.sampleRate.quantityInBaseUnits;

                % Extract the onset window.
                onsetSample = round(obj.preTime / 1e3 * sr) + 1;
                preWinSamples = round(obj.prePad / 1e3 * sr);
                postWinSamples = round(obj.postPad / 1e3 * sr);

                winStart = max(1, onsetSample - preWinSamples);
                winEnd = min(numel(quantities), onsetSample + postWinSamples - 1);

                if winEnd <= winStart
                    return;
                end

                snippet = quantities(winStart:winEnd);
                tMs = ((winStart:winEnd) - onsetSample) / sr * 1e3;

                obj.epochCount = obj.epochCount + 1;

                % Determine group key.
                groupKey = 0;  % default: all in one group
                if ~isempty(obj.groupBy)
                    p = epoch.parameters;
                    if p.isKey(obj.groupBy)
                        groupKey = p(obj.groupBy);
                    end
                end

                % Find or create group.
                gIdx = [];
                for i = 1:numel(obj.groups)
                    if obj.groups{i}.key == groupKey
                        gIdx = i;
                        break;
                    end
                end

                if ~isempty(obj.ledDevice)
                    yyaxis(obj.axHandle, 'left');
                end

                if isempty(gIdx)
                    % New group.
                    g = struct();
                    g.key = groupKey;
                    g.sumY = snippet(:)';
                    g.count = 1;
                    colorIdx = mod(numel(obj.groups), size(obj.colorOrder, 1)) + 1;
                    g.color = obj.colorOrder(colorIdx, :);
                    g.lineHandle = plot(obj.axHandle, tMs, snippet, ...
                        'Color', g.color, 'LineWidth', 1.2);
                    g.tMs = tMs;
                    obj.groups{end + 1} = g;
                else
                    % Update running average.
                    g = obj.groups{gIdx};
                    nMin = min(numel(g.sumY), numel(snippet));
                    g.sumY = g.sumY(1:nMin) + snippet(1:nMin)';
                    g.count = g.count + 1;
                    g.tMs = tMs(1:nMin);
                    meanY = g.sumY / g.count;
                    set(g.lineHandle, 'XData', g.tMs, 'YData', meanY);
                    obj.groups{gIdx} = g;
                end

                xlim(obj.axHandle, [-obj.prePad, obj.postPad]);

                % Update onset line.
                yl = ylim(obj.axHandle);
                hLine = findobj(obj.axHandle, 'Tag', 'onsetLine');
                if ~isempty(hLine)
                    set(hLine, 'YData', yl);
                end

                nGroups = numel(obj.groups);
                title(obj.axHandle, sprintf('Flash Onset (mean, %d %s)', ...
                    nGroups, obj.pluralize('group', nGroups)));

                % --- LED stimulus overlay ---
                if ~isempty(obj.ledDevice) && epoch.hasStimulus(obj.ledDevice)
                    stim = epoch.getStimulus(obj.ledDevice);
                    [stimData, stimUnits] = stim.getData();
                    stimData = double(stimData);

                    stimWinEnd = min(numel(stimData), winEnd);
                    if winStart <= stimWinEnd
                        stimSnippet = stimData(winStart:stimWinEnd);
                        tStimMs = ((winStart:stimWinEnd) - onsetSample) / sr * 1e3;

                        yyaxis(obj.axHandle, 'right');

                        % One stimulus line per group.
                        slIdx = [];
                        for i = 1:numel(obj.stimLines)
                            if obj.stimLines{i}.key == groupKey
                                slIdx = i;
                                break;
                            end
                        end

                        if isempty(slIdx)
                            sl = struct();
                            sl.key = groupKey;
                            sl.lineHandle = plot(obj.axHandle, tStimMs, stimSnippet, ...
                                'Color', [0.85 0.33 0.10 0.4], ...
                                'LineWidth', 1.2, ...
                                'HandleVisibility', 'off');
                            obj.stimLines{end + 1} = sl;
                        else
                            set(obj.stimLines{slIdx}.lineHandle, ...
                                'XData', tStimMs, 'YData', stimSnippet);
                        end

                        ylabel(obj.axHandle, ['LED (' stimUnits ')'], 'Interpreter', 'none');
                        yyaxis(obj.axHandle, 'left');
                    end
                end

            catch ME
                fprintf(2, '[FlashOnsetFigure] %s\n', ME.message);
            end
        end

        function clear(obj)
            if ~isempty(obj.ledDevice)
                yyaxis(obj.axHandle, 'right');
                cla(obj.axHandle);
                yyaxis(obj.axHandle, 'left');
            end
            cla(obj.axHandle);
            hold(obj.axHandle, 'on');
            obj.epochCount = 0;
            obj.groups = {};
            obj.stimLines = {};

            yl = ylim(obj.axHandle);
            line(obj.axHandle, [0 0], yl, ...
                'Color', [0.6 0.6 0.6], 'LineStyle', '--', ...
                'Tag', 'onsetLine', 'HandleVisibility', 'off');
        end

    end

    methods (Access = private, Static)
        function s = pluralize(word, n)
            if n == 1
                s = word;
            else
                s = [word 's'];
            end
        end
    end

end
