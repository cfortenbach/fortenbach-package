classdef PowerSpectrumFigure < symphonyui.core.FigureHandler
    % POWERSPECTRUMFIGURE  Running-average power spectrum (1–80 Hz).
    %
    %   Computes the single-sided power spectral density of each epoch's
    %   response and displays the running average across all epochs.
    %
    %   Usage in a protocol's prepareRun():
    %     obj.showFigure('fortenbachlab.figures.PowerSpectrumFigure', ...
    %         obj.rig.getDevice(obj.amp), ...
    %         'freqRange', [1 80]);

    properties (SetAccess = private)
        device
        freqRange   % [fLow fHigh] in Hz
    end

    properties (Access = private)
        ax
        sumPsd      % Running sum of PSDs (for averaging)
        epochCount
        freqAxis    % Frequency vector (Hz), set on first epoch
    end

    methods

        function obj = PowerSpectrumFigure(device, varargin)
            obj.device = device;
            obj.freqRange = [1 80];
            obj.sumPsd = [];
            obj.epochCount = 0;
            obj.freqAxis = [];

            ip = inputParser();
            ip.addParameter('freqRange', [1 80]);
            ip.parse(varargin{:});
            obj.freqRange = ip.Results.freqRange;

            obj.createUi();
        end

        function createUi(obj)
            set(obj.figureHandle, 'Name', 'Power Spectrum');

            obj.ax = axes('Parent', obj.figureHandle);
            xlabel(obj.ax, 'Frequency (Hz)');
            ylabel(obj.ax, 'Power (units^2/Hz)');
            title(obj.ax, 'Running Average Power Spectrum');
            grid(obj.ax, 'on');
            set(obj.ax, 'XScale', 'log');
            set(obj.ax, 'YScale', 'log');
        end

        function handleEpoch(obj, epoch)
            try
                if ~epoch.hasResponse(obj.device)
                    return;
                end

                response = epoch.getResponse(obj.device);
                [quantities, ~] = response.getData();
                sr = response.sampleRate.quantityInBaseUnits;
                nPts = numel(quantities);

                % Detrend to remove DC offset / slow drift.
                quantities = detrend(quantities);

                % Compute single-sided PSD via FFT.
                Y = fft(quantities);
                P2 = abs(Y / nPts).^2;
                % Single-sided spectrum.
                nHalf = floor(nPts / 2) + 1;
                P1 = P2(1:nHalf);
                P1(2:end-1) = 2 * P1(2:end-1);
                freqs = (0:nHalf-1) * (sr / nPts);

                % Convert to power spectral density (per Hz).
                df = sr / nPts;
                psd = P1 / df;

                % Accumulate running sum.
                if isempty(obj.sumPsd)
                    obj.sumPsd = psd;
                    obj.freqAxis = freqs;
                else
                    % Handle possible length mismatch if epoch
                    % duration changes (shouldn't happen, but be safe).
                    nMin = min(numel(obj.sumPsd), numel(psd));
                    obj.sumPsd = obj.sumPsd(1:nMin) + psd(1:nMin);
                    obj.freqAxis = obj.freqAxis(1:nMin);
                end
                obj.epochCount = obj.epochCount + 1;

                % Compute running average.
                avgPsd = obj.sumPsd / obj.epochCount;

                % Restrict to requested frequency range.
                fMask = obj.freqAxis >= obj.freqRange(1) & ...
                        obj.freqAxis <= obj.freqRange(2);

                cla(obj.ax);
                plot(obj.ax, obj.freqAxis(fMask), avgPsd(fMask), ...
                    'Color', [0 0.45 0.74], 'LineWidth', 1.2);
                xlabel(obj.ax, 'Frequency (Hz)');
                ylabel(obj.ax, 'Power (units^2/Hz)');
                title(obj.ax, sprintf('Power Spectrum  (n = %d)', obj.epochCount));
                set(obj.ax, 'XScale', 'log');
                set(obj.ax, 'YScale', 'log');
                grid(obj.ax, 'on');
                xlim(obj.ax, obj.freqRange);

            catch ME
                fprintf(2, '[PowerSpectrumFigure] %s\n', ME.message);
            end
        end

        function clear(obj)
            obj.sumPsd = [];
            obj.epochCount = 0;
            obj.freqAxis = [];
            cla(obj.ax);
        end

    end

end
