classdef IntensityResponseFigure < symphonyui.core.FigureHandler
    % INTENSITYRESPONSEFIGURE  Plots peak response vs. flash intensity.
    %
    %   Builds an intensity-response curve as epochs arrive.  Each epoch's
    %   photon flux (from the 'photonFluxPeak' epoch parameter) is plotted
    %   on a log-scaled x-axis against the peak response amplitude
    %   (measured relative to the pre-stimulus baseline).
    %
    %   When multiple repeats of the same intensity are collected, the
    %   figure shows the running mean +/- SEM for each intensity.
    %
    %   Usage in a protocol's prepareRun():
    %     obj.showFigure('fortenbachlab.figures.IntensityResponseFigure', ...
    %         obj.rig.getDevice(obj.amp), ...
    %         'preTime', obj.preTime, ...
    %         'stimTime', obj.stimTime);
    %
    %   Parameters:
    %     preTime  - pre-stimulus duration in ms (for baseline)
    %     stimTime - stimulus duration in ms (for response measurement)

    properties (SetAccess = private)
        device
        preTime     % ms
        stimTime    % ms
    end

    properties (Access = private)
        ax
        % Accumulated data: each entry is a struct with fields
        %   flux, responses (vector of peak amplitudes)
        dataPoints
    end

    methods

        function obj = IntensityResponseFigure(device, varargin)
            ip = inputParser();
            ip.addParameter('preTime', 50, @isnumeric);
            ip.addParameter('stimTime', 10, @isnumeric);
            ip.parse(varargin{:});

            obj.device = device;
            obj.preTime = ip.Results.preTime;
            obj.stimTime = ip.Results.stimTime;
            obj.dataPoints = {};

            obj.createUi();
        end

        function createUi(obj)
            set(obj.figureHandle, 'Name', 'Intensity-Response');

            obj.ax = axes('Parent', obj.figureHandle);
            xlabel(obj.ax, 'Photon Flux (photons/cm^2/s)');
            ylabel(obj.ax, 'Peak Response');
            title(obj.ax, 'Intensity-Response Curve');
            set(obj.ax, 'XScale', 'log');
            grid(obj.ax, 'on');
            hold(obj.ax, 'on');
        end

        function handleEpoch(obj, epoch)
            try
                if ~epoch.hasResponse(obj.device)
                    return;
                end

                % Get photon flux from epoch parameters.
                p = epoch.parameters;
                if ~p.isKey('photonFluxPeak')
                    return;
                end
                flux = p('photonFluxPeak');
                if ~isfinite(flux) || flux <= 0
                    return;
                end

                % Compute peak response relative to baseline.
                response = epoch.getResponse(obj.device);
                [quantities, ~] = response.getData();
                sr = response.sampleRate.quantityInBaseUnits;

                baselineEnd = round(obj.preTime / 1e3 * sr);
                stimStart = baselineEnd + 1;
                stimEnd = stimStart + round(obj.stimTime / 1e3 * sr) - 1;
                stimEnd = min(stimEnd, numel(quantities));

                if baselineEnd < 1 || stimStart > numel(quantities)
                    return;
                end

                baseline = mean(quantities(1:baselineEnd));
                stimRegion = quantities(stimStart:stimEnd);

                % Use the peak deflection (max absolute deviation from
                % baseline) with sign preserved.
                [~, peakIdx] = max(abs(stimRegion - baseline));
                peakAmplitude = stimRegion(peakIdx) - baseline;

                % Find or create the entry for this flux level.
                % Use a tolerance of 1% to group identical intensities
                % that may differ by floating-point rounding.
                entryIdx = [];
                for i = 1:numel(obj.dataPoints)
                    if abs(log10(obj.dataPoints{i}.flux) - log10(flux)) < 0.01
                        entryIdx = i;
                        break;
                    end
                end

                if isempty(entryIdx)
                    entry.flux = flux;
                    entry.responses = peakAmplitude;
                    obj.dataPoints{end + 1} = entry;
                else
                    obj.dataPoints{entryIdx}.responses(end + 1) = peakAmplitude;
                end

                % Redraw the curve.
                obj.redraw();

            catch ME
                fprintf(2, '[IntensityResponseFigure] %s\n', ME.message);
            end
        end

        function redraw(obj)
            cla(obj.ax);
            hold(obj.ax, 'on');

            n = numel(obj.dataPoints);
            if n == 0
                return;
            end

            fluxVals = zeros(1, n);
            meanResp = zeros(1, n);
            semResp  = zeros(1, n);
            counts   = zeros(1, n);

            for i = 1:n
                fluxVals(i) = obj.dataPoints{i}.flux;
                r = obj.dataPoints{i}.responses;
                meanResp(i) = mean(r);
                counts(i) = numel(r);
                if counts(i) > 1
                    semResp(i) = std(r) / sqrt(counts(i));
                else
                    semResp(i) = 0;
                end
            end

            % Sort by flux.
            [fluxVals, sortIdx] = sort(fluxVals);
            meanResp = meanResp(sortIdx);
            semResp  = semResp(sortIdx);
            counts   = counts(sortIdx);

            % Plot mean +/- SEM error bars.
            hasError = any(semResp > 0);
            if hasError
                errorbar(obj.ax, fluxVals, meanResp, semResp, 'o-', ...
                    'Color', [0 0.45 0.74], ...
                    'MarkerFaceColor', [0 0.45 0.74], ...
                    'MarkerSize', 6, ...
                    'LineWidth', 1.2, ...
                    'CapSize', 8);
            else
                plot(obj.ax, fluxVals, meanResp, 'o-', ...
                    'Color', [0 0.45 0.74], ...
                    'MarkerFaceColor', [0 0.45 0.74], ...
                    'MarkerSize', 6, ...
                    'LineWidth', 1.2);
            end

            % Also scatter individual points in light grey if there are
            % repeats, so the spread is visible.
            if any(counts > 1)
                for i = 1:n
                    idx = sortIdx(i);
                    r = obj.dataPoints{idx}.responses;
                    if numel(r) > 1
                        scatter(obj.ax, repmat(fluxVals(i), 1, numel(r)), r, ...
                            15, [0.7 0.7 0.7], 'filled', ...
                            'MarkerFaceAlpha', 0.4, ...
                            'HandleVisibility', 'off');
                    end
                end
            end

            set(obj.ax, 'XScale', 'log');
            xlabel(obj.ax, 'Photon Flux (photons/cm^2/s)');
            ylabel(obj.ax, 'Peak Response');
            title(obj.ax, sprintf('Intensity-Response  (%d intensities)', n));
            grid(obj.ax, 'on');
        end

        function clear(obj)
            cla(obj.ax);
            hold(obj.ax, 'on');
            obj.dataPoints = {};
        end

    end

end
