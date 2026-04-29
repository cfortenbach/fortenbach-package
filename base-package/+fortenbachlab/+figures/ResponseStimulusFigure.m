classdef ResponseStimulusFigure < symphonyui.core.FigureHandler
    % RESPONSESTIMULUSFIGURE  Drop-in replacement for ResponseFigure with
    % LED stimulus overlay on a secondary y-axis.
    %
    %   Usage in a protocol's prepareRun():
    %     obj.showFigure('fortenbachlab.figures.ResponseStimulusFigure', ...
    %         obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.led));

    properties (SetAccess = private)
        ampDevice
        ledDevice
    end

    properties (Access = private)
        ax
    end

    methods

        function obj = ResponseStimulusFigure(ampDevice, ledDevice, varargin)
            obj.ampDevice = ampDevice;
            obj.ledDevice = ledDevice;
            obj.createUi();
        end

        function createUi(obj)
            set(obj.figureHandle, 'Name', [obj.ampDevice.name ' Response']);
            obj.ax = axes('Parent', obj.figureHandle);
            xlabel(obj.ax, 'sec');
            title(obj.ax, [obj.ampDevice.name ' Response']);
        end

        function handleEpoch(obj, epoch)
            try
                if ~epoch.hasResponse(obj.ampDevice)
                    return;
                end

                response = epoch.getResponse(obj.ampDevice);
                [respData, respUnits] = response.getData();
                sr = response.sampleRate.quantityInBaseUnits;
                tSec = (1:numel(respData)) / sr;

                % --- Response on left y-axis ---
                yyaxis(obj.ax, 'left');
                cla(obj.ax);
                plot(obj.ax, tSec, respData, ...
                    'Color', [0 0.45 0.74], 'LineWidth', 0.8);
                ylabel(obj.ax, respUnits, 'Interpreter', 'none');
                obj.ax.YColor = [0 0.15 0.35];

                % --- LED stimulus on right y-axis ---
                yyaxis(obj.ax, 'right');
                cla(obj.ax);
                if epoch.hasStimulus(obj.ledDevice)
                    stim = epoch.getStimulus(obj.ledDevice);
                    [stimData, stimUnits] = stim.getData();
                    stimData = double(stimData);
                    tStim = (1:numel(stimData)) / sr;
                    plot(obj.ax, tStim, stimData, ...
                        'Color', [0.85 0.33 0.10 0.5], 'LineWidth', 1.2);
                    ylabel(obj.ax, ['LED (' stimUnits ')'], 'Interpreter', 'none');
                end
                obj.ax.YColor = [0.85 0.33 0.10];

                yyaxis(obj.ax, 'left');
                xlabel(obj.ax, 'sec');
                title(obj.ax, [obj.ampDevice.name ' Response']);
                grid(obj.ax, 'on');

            catch ME
                fprintf(2, '[ResponseStimulusFigure] %s\n', ME.message);
            end
        end

        function clear(obj)
            yyaxis(obj.ax, 'left');
            cla(obj.ax);
            yyaxis(obj.ax, 'right');
            cla(obj.ax);
        end

    end

end
