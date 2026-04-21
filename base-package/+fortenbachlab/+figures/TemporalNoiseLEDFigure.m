classdef TemporalNoiseLEDFigure < symphonyui.core.FigureHandler
    % Online temporal filter analysis for LED noise stimuli.
    %
    % Computes and displays:
    %   - Left panel: Linear temporal filter (reverse correlation of stimulus
    %     contrast with response), updated after each epoch.
    %   - Right panel: Static nonlinearity (binned predicted vs actual response).
    %
    % Usage in a protocol's prepareRun:
    %   obj.showFigure('fortenbachlab.figures.TemporalNoiseLEDFigure', ...
    %       obj.rig.getDevice(obj.amp), ...
    %       'preTime', obj.preTime, ...
    %       'stimTime', obj.stimTime);
    %
    % The protocol must store the contrast time series as an epoch parameter
    % named 'contrast' (row vector of (V - mean)/mean during stimTime).

    properties (SetAccess = private)
        device
        preTime
        stimTime
    end

    properties (Access = private)
        axesHandle          % Linear filter axes
        nlAxesHandle        % Nonlinearity axes
        linearFilter
        epochCount
        nonlinearityBins = 100
        S                   % Stimulus contrast matrix (epochs x bins)
        R                   % Response matrix (epochs x bins)
        P                   % Prediction matrix (epochs x bins)
    end

    methods

        function obj = TemporalNoiseLEDFigure(device, varargin)
            ip = inputParser();
            ip.addParameter('preTime', 0.0, @isfloat);
            ip.addParameter('stimTime', 0.0, @isfloat);
            ip.parse(varargin{:});

            obj.device = device;
            obj.preTime = ip.Results.preTime;
            obj.stimTime = ip.Results.stimTime;

            obj.epochCount = 0;

            obj.createUi();
        end

        function createUi(obj)
            import appbox.*;

            obj.axesHandle = subplot(1, 3, 1:2, ...
                'Parent', obj.figureHandle, ...
                'FontUnits', get(obj.figureHandle, 'DefaultUicontrolFontUnits'), ...
                'FontName', get(obj.figureHandle, 'DefaultUicontrolFontName'), ...
                'FontSize', get(obj.figureHandle, 'DefaultUicontrolFontSize'), ...
                'XTickMode', 'auto');
            xlabel(obj.axesHandle, 'Time (s)');
            ylabel(obj.axesHandle, 'Filter weight');

            obj.nlAxesHandle = subplot(1, 3, 3, ...
                'Parent', obj.figureHandle, ...
                'FontUnits', get(obj.figureHandle, 'DefaultUicontrolFontUnits'), ...
                'FontName', get(obj.figureHandle, 'DefaultUicontrolFontName'), ...
                'FontSize', get(obj.figureHandle, 'DefaultUicontrolFontSize'), ...
                'XTickMode', 'auto');
            xlabel(obj.nlAxesHandle, 'Linear prediction');
            ylabel(obj.nlAxesHandle, 'Response');

            obj.linearFilter = [];
            obj.S = [];
            obj.R = [];
            obj.P = [];

            obj.setTitle([obj.device.name ': Temporal Filter']);
        end

        function setTitle(obj, t)
            set(obj.figureHandle, 'Name', t);
        end

        function clear(obj)
            cla(obj.axesHandle);
            cla(obj.nlAxesHandle);
            obj.linearFilter = [];
            obj.S = [];
            obj.R = [];
            obj.P = [];
            obj.epochCount = 0;
        end

        function handleEpoch(obj, epoch)
            if ~epoch.hasResponse(obj.device)
                error(['Epoch does not contain a response for ' obj.device.name]);
            end

            obj.epochCount = obj.epochCount + 1;

            % Target bin rate for analysis (downsample to this).
            binRate = 200;

            % Get the response.
            response = epoch.getResponse(obj.device);
            [quantities, ~] = response.getData();
            sampleRate = response.sampleRate.quantityInBaseUnits;
            prePts = round(obj.preTime * 1e-3 * sampleRate);
            stimPts = round(obj.stimTime * 1e-3 * sampleRate);

            if numel(quantities) < prePts + stimPts
                return;
            end

            % Extract the stimulus period and baseline-subtract.
            y = quantities(:)';
            if prePts > 0
                y = y - median(y(1:prePts));
            else
                y = y - median(y);
            end
            y = y(prePts + (1:stimPts));

            % Downsample response by binning.
            y = obj.binData(y, binRate, sampleRate);
            y = y(:)';

            % Get the contrast time series from epoch parameters.
            if ~epoch.parameters.isKey('contrast')
                return;
            end
            frameValues = epoch.parameters('contrast');
            frameValues = frameValues(:)';

            % Downsample contrast to match.
            stimBins = round(obj.stimTime * 1e-3 * binRate);
            if numel(frameValues) > stimBins
                frameValues = obj.binData(frameValues(1:stimPts), binRate, sampleRate);
            end
            frameValues = frameValues(:)';

            % Ensure same length.
            minLen = min(numel(y), numel(frameValues));
            y = y(1:minLen);
            frameValues = frameValues(1:minLen);

            % Zero out the first 0.5 seconds (adaptation transient).
            adaptBins = floor(binRate / 2);
            if adaptBins < minLen
                y(1:adaptBins) = 0;
                frameValues(1:adaptBins) = 0;
            end

            % Accumulate across epochs.
            obj.R(obj.epochCount, :) = y;
            obj.S(obj.epochCount, :) = frameValues;

            % Compute linear filter via reverse correlation (all epochs).
            padLen = 100;
            lf = real(ifft(mean( ...
                fft([obj.R, zeros(size(obj.R, 1), padLen)], [], 2) .* ...
                conj(fft([obj.S, zeros(size(obj.S, 1), padLen)], [], 2)), 1)));
            lf = lf / norm(lf);
            obj.linearFilter = lf;

            % Compute linear predictions for nonlinearity.
            if obj.epochCount > 1 && obj.epochCount < 25
                % Recompute all predictions with updated filter.
                for k = 1:size(obj.S, 1)
                    pred = ifft(fft([obj.S(k, :) zeros(1, padLen)]) .* fft(obj.linearFilter));
                    pred = real(pred(:)');
                    obj.P(k, :) = pred(1:minLen);
                end
            else
                % Just compute this epoch's prediction.
                pred = ifft(fft([frameValues zeros(1, padLen)]) .* fft(obj.linearFilter));
                pred = real(pred(:)');
                obj.P(obj.epochCount, :) = pred(1:minLen);
            end

            % Bin the nonlinearity.
            pTrimmed = obj.P(:, adaptBins+1:end);
            rTrimmed = obj.R(:, adaptBins+1:end);
            [xBin, yBin] = obj.getNonlinearity(pTrimmed, rTrimmed);

            % --- Plot linear filter ---
            plotLength = min(round(0.5 * binRate), numel(obj.linearFilter));
            cla(obj.axesHandle);
            line((1:plotLength) / binRate, obj.linearFilter(1:plotLength), ...
                'Parent', obj.axesHandle, 'Color', 'k', 'LineWidth', 1.5);
            axis(obj.axesHandle, 'tight');
            xlabel(obj.axesHandle, 'Time (s)');
            ylabel(obj.axesHandle, 'Filter weight');
            title(obj.axesHandle, sprintf('Linear filter (n=%d)', obj.epochCount));

            % --- Plot nonlinearity ---
            cla(obj.nlAxesHandle);
            line(xBin, yBin, ...
                'Parent', obj.nlAxesHandle, 'Color', 'k', 'LineWidth', 1.5);
            axis(obj.nlAxesHandle, 'tight');
            xlabel(obj.nlAxesHandle, 'Linear prediction');
            ylabel(obj.nlAxesHandle, 'Response');
            title(obj.nlAxesHandle, 'Nonlinearity');
        end

    end

    methods (Access = private)

        function [xBin, yBin] = getNonlinearity(obj, P, R)
            % Sort by prediction, bin into obj.nonlinearityBins bins.
            [a, b] = sort(P(:));
            R = R(:);
            xSort = a;
            ySort = R(b);

            valsPerBin = floor(numel(xSort) / obj.nonlinearityBins);
            if valsPerBin < 1
                xBin = mean(xSort);
                yBin = mean(ySort);
                return;
            end

            usable = obj.nonlinearityBins * valsPerBin;
            xBin = mean(reshape(xSort(1:usable), valsPerBin, obj.nonlinearityBins));
            yBin = mean(reshape(ySort(1:usable), valsPerBin, obj.nonlinearityBins));
        end

    end

    methods (Static)

        function binned = binData(data, binRate, sampleRate)
            % Downsample data by averaging within bins.
            binSize = round(sampleRate / binRate);
            if binSize <= 1
                binned = data;
                return;
            end
            nBins = floor(numel(data) / binSize);
            binned = mean(reshape(data(1:nBins * binSize), binSize, nBins), 1);
        end

    end

end
