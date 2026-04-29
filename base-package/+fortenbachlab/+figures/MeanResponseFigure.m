classdef MeanResponseFigure < symphonyui.core.FigureHandler
    % Plots the mean response of a specified device for all epochs run.
    %
    % Optional: pass 'ledDevice' to overlay the LED stimulus waveform on a
    % secondary y-axis. The most recent stimulus for each group is shown.
    %
    %   obj.showFigure('fortenbachlab.figures.MeanResponseFigure', ...
    %       obj.rig.getDevice(obj.amp), ...
    %       'groupBy', {'lightAmplitude'}, ...
    %       'ledDevice', obj.rig.getDevice(obj.led));

    properties (SetAccess = private)
        device
        groupBy
        sweepColor
        storedSweepColor
        psth
        ledDevice       % Optional: LED device for stimulus overlay
    end

    properties (Access = private)
        axesHandle
        sweeps
        stimLines       % Handles to stimulus lines on the right axis
    end

    methods

        function obj = MeanResponseFigure(device, varargin)
            co = get(groot, 'defaultAxesColorOrder');

            ip = inputParser();
            ip.addParameter('groupBy', [], @(x)iscellstr(x));
            ip.addParameter('sweepColor', co(1,:), @(x)ischar(x) || ismatrix(x));
            ip.addParameter('storedSweepColor', 'r', @(x)ischar(x) || isvector(x));
            ip.addParameter('psth', false, @(x)islogical(x));
            ip.addParameter('ledDevice', [], @(x)isempty(x) || isobject(x));
            ip.parse(varargin{:});

            obj.device = device;
            obj.groupBy = ip.Results.groupBy;
            obj.sweepColor = ip.Results.sweepColor;
            obj.storedSweepColor = ip.Results.storedSweepColor;
            obj.psth = ip.Results.psth;
            obj.ledDevice = ip.Results.ledDevice;
            obj.stimLines = {};

            obj.createUi();

            % Restore stored sweeps on the left axis.
            if ~isempty(obj.ledDevice)
                yyaxis(obj.axesHandle, 'left');
            end
            stored = obj.storedSweeps();
            for i = 1:numel(stored)
                stored{i}.line = line(stored{i}.x, stored{i}.y, ...
                    'Parent', obj.axesHandle, ...
                    'Color', obj.storedSweepColor, ...
                    'HandleVisibility', 'off');
            end
            obj.storedSweeps(stored);
        end

        function createUi(obj)
            import appbox.*;

            toolbar = findall(obj.figureHandle, 'Type', 'uitoolbar');
            storeSweepsButton = uipushtool( ...
                'Parent', toolbar, ...
                'TooltipString', 'Store Sweeps', ...
                'Separator', 'on', ...
                'ClickedCallback', @obj.onSelectedStoreSweeps);
            setIconImage(storeSweepsButton, symphonyui.app.App.getResource('icons', 'sweep_store.png'));

            clearSweepsButton = uipushtool( ...
                'Parent', toolbar, ...
                'TooltipString', 'Clear Sweeps', ...
                'ClickedCallback', @obj.onSelectedClearSweeps);
            setIconImage(clearSweepsButton, symphonyui.app.App.getResource('icons', 'sweep_clear.png'));

            obj.axesHandle = axes( ...
                'Parent', obj.figureHandle, ...
                'XTickMode', 'auto');
            xlabel(obj.axesHandle, 'sec');
            obj.sweeps = {};

            % Set up yyaxis if LED overlay is enabled.
            if ~isempty(obj.ledDevice)
                yyaxis(obj.axesHandle, 'right');
                ylabel(obj.axesHandle, 'LED (V)', 'Interpreter', 'none');
                obj.axesHandle.YColor = [0.85 0.33 0.10];
                yyaxis(obj.axesHandle, 'left');
                obj.axesHandle.YColor = [0 0.15 0.35];
            end

            obj.setTitle([obj.device.name ' Mean Response']);
        end

        function setTitle(obj, t)
            set(obj.figureHandle, 'Name', t);
            title(obj.axesHandle, t);
        end

        function clear(obj)
            if ~isempty(obj.ledDevice)
                yyaxis(obj.axesHandle, 'right');
                cla(obj.axesHandle);
                yyaxis(obj.axesHandle, 'left');
            end
            cla(obj.axesHandle);
            obj.sweeps = {};
            obj.stimLines = {};
        end

        function handleEpoch(obj, epoch)
            if ~epoch.hasResponse(obj.device)
                error(['Epoch does not contain a response for ' obj.device.name]);
            end

            response = epoch.getResponse(obj.device);
            [quantities, units] = response.getData();
            if numel(quantities) > 0
                sampleRate = response.sampleRate.quantityInBaseUnits;
                x = (1:numel(quantities)) / sampleRate;
                y = quantities;
                if obj.psth
                    sigma = 15e-3 * sampleRate;
                    filter = normpdf(1:10*sigma, 10*sigma/2, sigma);
                    results = edu.washington.riekelab.util.spikeDetectorOnline(y, [], sampleRate);
                    y = zeros(size(y));
                    y(results.sp) = 1;
                    y = sampleRate * conv(y, filter, 'same');
                end
            else
                x = [];
                y = [];
            end

            p = epoch.parameters;
            if isempty(obj.groupBy) && isnumeric(obj.groupBy)
                parameters = p;
            else
                parameters = containers.Map();
                for i = 1:length(obj.groupBy)
                    key = obj.groupBy{i};
                    parameters(key) = p(key);
                end
            end

            if isempty(parameters)
                t = 'All epochs grouped together';
            else
                t = ['Grouped by ' strjoin(parameters.keys, ', ')];
            end
            obj.setTitle([obj.device.name ' Mean Response (' t ')']);

            % Ensure sweep lines go on the left axis.
            if ~isempty(obj.ledDevice)
                yyaxis(obj.axesHandle, 'left');
            end

            sweepIndex = [];
            for i = 1:numel(obj.sweeps)
                if isequal(obj.sweeps{i}.parameters, parameters)
                    sweepIndex = i;
                    break;
                end
            end

            if isempty(sweepIndex)
                sweep.parameters = parameters;
                sweep.x = x;
                sweep.y = y;
                sweep.count = 1;
                colorIndex = mod(numel(obj.sweeps), size(obj.sweepColor, 1)) + 1;
                sweep.line = line(sweep.x, sweep.y, 'Parent', obj.axesHandle, 'Color', obj.sweepColor(colorIndex, :));
                obj.sweeps{end + 1} = sweep;
            else
                sweep = obj.sweeps{sweepIndex};
                sweep.y = (sweep.y * sweep.count + y) / (sweep.count + 1);
                sweep.count = sweep.count + 1;
                set(sweep.line, 'YData', sweep.y);
                obj.sweeps{sweepIndex} = sweep;
            end

            if obj.psth
                ylabel(obj.axesHandle, 'Hz');
            else
                ylabel(obj.axesHandle, units, 'Interpreter', 'none');
            end

            % --- LED stimulus overlay on right y-axis ---
            if ~isempty(obj.ledDevice) && epoch.hasStimulus(obj.ledDevice)
                try
                    stim = epoch.getStimulus(obj.ledDevice);
                    [stimData, stimUnits] = stim.getData();
                    stimData = double(stimData);
                    tStim = (1:numel(stimData)) / sampleRate;

                    yyaxis(obj.axesHandle, 'right');

                    % Remove the old stimulus line for this group (if any)
                    % so we always show the most recent stimulus shape.
                    stimIdx = [];
                    for i = 1:numel(obj.stimLines)
                        if isequal(obj.stimLines{i}.parameters, parameters)
                            stimIdx = i;
                            break;
                        end
                    end

                    if isempty(stimIdx)
                        sl = struct();
                        sl.parameters = parameters;
                        sl.line = line(tStim, stimData, ...
                            'Parent', obj.axesHandle, ...
                            'Color', [0.85 0.33 0.10 0.4], ...
                            'LineWidth', 1.2, ...
                            'HandleVisibility', 'off');
                        obj.stimLines{end + 1} = sl;
                    else
                        set(obj.stimLines{stimIdx}.line, ...
                            'XData', tStim, 'YData', stimData);
                    end

                    ylabel(obj.axesHandle, ['LED (' stimUnits ')'], 'Interpreter', 'none');

                    yyaxis(obj.axesHandle, 'left');
                catch ME
                    fprintf(2, '[MeanResponseFigure] Stimulus overlay error: %s\n', ME.message);
                end
            end
        end

    end

    methods (Access = private)

        function onSelectedStoreSweeps(obj, ~, ~)
            obj.storeSweeps();
        end

        function storeSweeps(obj)
            obj.clearSweeps();

            if ~isempty(obj.ledDevice)
                yyaxis(obj.axesHandle, 'left');
            end

            store = obj.sweeps;
            for i = 1:numel(obj.sweeps)
                store{i}.line = copyobj(obj.sweeps{i}.line, obj.axesHandle);
                set(store{i}.line, ...
                    'Color', obj.storedSweepColor, ...
                    'HandleVisibility', 'off');
            end
            obj.storedSweeps(store);
        end

        function onSelectedClearSweeps(obj, ~, ~)
            obj.clearSweeps();
        end

        function clearSweeps(obj)
            stored = obj.storedSweeps();
            for i = 1:numel(stored)
                delete(stored{i}.line);
            end

            obj.storedSweeps([]);
        end

    end

    methods (Static)

        function sweeps = storedSweeps(sweeps)
            % This method stores sweeps across figure handlers.

            persistent stored;
            if nargin > 0
                stored = sweeps;
            end
            sweeps = stored;
        end

    end

end
