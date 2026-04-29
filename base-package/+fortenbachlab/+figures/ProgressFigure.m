classdef ProgressFigure < symphonyui.core.FigureHandler

    properties (SetAccess = private)
        totalNumEpochs
    end

    properties (Access = private)
        numEpochsCompleted
        numIntervalsCompleted
        averageEpochDuration
        averageIntervalDuration
        statusText
        progressBar
        timeText
        flashText           % Shows voltage / NDF / intensity for flash protocols
        flashVoltages       % Voltage for each pulse in the family (numeric array)
        flashNdfs           % NDF for each pulse in the family (numeric array)
        flashFluxes         % Photon flux for each pulse in the family (numeric array)
        pulsesInFamily      % Number of pulses per family cycle
    end

    methods

        function obj = ProgressFigure(totalNumEpochs, varargin)
            ip = inputParser();
            ip.addParameter('flashVoltages', [], @isnumeric);
            ip.addParameter('flashNdfs', [], @isnumeric);
            ip.addParameter('flashFluxes', [], @isnumeric);
            ip.addParameter('pulsesInFamily', 1, @isnumeric);
            ip.parse(varargin{:});

            obj.totalNumEpochs = double(totalNumEpochs);
            obj.numEpochsCompleted = 0;
            obj.numIntervalsCompleted = 0;
            obj.flashVoltages = ip.Results.flashVoltages;
            obj.flashNdfs = ip.Results.flashNdfs;
            obj.flashFluxes = ip.Results.flashFluxes;
            obj.pulsesInFamily = double(ip.Results.pulsesInFamily);

            obj.createUi();

            obj.updateProgress();
            obj.updateFlashInfo();
        end
        
        function createUi(obj)
            import appbox.*;
            
            mainLayout = uix.VBox( ...
                'Parent', obj.figureHandle, ...
                'Padding', 11);
            
            uix.Empty('Parent', mainLayout);
            
            progressLayout = uix.VBox( ...
                'Parent', mainLayout, ...
                'Spacing', 5);
            obj.statusText = Label( ...
                'Parent', progressLayout, ...
                'String', '', ...
                'HorizontalAlignment', 'left');
            obj.progressBar = javacomponent(javax.swing.JProgressBar(), [], progressLayout);
            obj.progressBar.setMaximum(obj.totalNumEpochs);
            obj.timeText = Label( ...
                'Parent', progressLayout, ...
                'String', '', ...
                'HorizontalAlignment', 'left');
            obj.flashText = Label( ...
                'Parent', progressLayout, ...
                'String', '', ...
                'HorizontalAlignment', 'left');
            set(progressLayout, 'Heights', [23 20 23 23]);

            uix.Empty('Parent', mainLayout);

            set(mainLayout, 'Heights', [-1 23+5+20+5+23+5+23 -1]);
            
            set(obj.figureHandle, 'Name', 'Progress');
            set(obj.figureHandle, 'Toolbar', 'none');
            
            if isempty(obj.settings.figurePosition)
                p = get(obj.figureHandle, 'Position');
                set(obj.figureHandle, 'Position', [p(1) p(2) p(3) 155]);
            end
        end
        
        function handleEpochOrInterval(obj, epochOrInterval)
            if epochOrInterval.isInterval()
                obj.numIntervalsCompleted = obj.numIntervalsCompleted + 1;
                
                interval = epochOrInterval;
                if isempty(obj.averageIntervalDuration)
                    obj.averageIntervalDuration = interval.duration;
                else
                    obj.averageIntervalDuration = obj.averageIntervalDuration * (obj.numIntervalsCompleted - 1)/obj.numIntervalsCompleted + interval.duration/obj.numIntervalsCompleted;
                end
            else
                obj.numEpochsCompleted = obj.numEpochsCompleted + 1;

                epoch = epochOrInterval;
                if isempty(obj.averageEpochDuration)
                    obj.averageEpochDuration = epoch.duration;
                else
                    obj.averageEpochDuration = obj.averageEpochDuration * (obj.numEpochsCompleted - 1)/obj.numEpochsCompleted + epoch.duration/obj.numEpochsCompleted;
                end

                obj.updateProgress();
                obj.updateFlashInfo();
            end
        end
        
        function clear(obj)
            obj.numEpochsCompleted = 0;
            obj.numIntervalsCompleted = 0;
            obj.averageEpochDuration = [];
            obj.averageIntervalDuration = [];
            set(obj.flashText, 'String', '');

            obj.updateProgress();
        end

        function updateFlashInfo(obj)
            % Show voltage, NDF, and photon flux for the flash that is
            % currently playing (i.e. the epoch AFTER the last one that
            % completed). Called at construction (before any epoch plays)
            % and after each epoch completes.
            if isempty(obj.flashVoltages)
                return;
            end

            nextEpoch = obj.numEpochsCompleted + 1;
            if nextEpoch > obj.totalNumEpochs
                set(obj.flashText, 'String', 'Complete');
                return;
            end

            pulseIdx = mod(nextEpoch - 1, obj.pulsesInFamily) + 1;
            voltage = obj.flashVoltages(pulseIdx);
            ndf = obj.flashNdfs(pulseIdx);

            fluxStr = '';
            if ~isempty(obj.flashFluxes) && pulseIdx <= numel(obj.flashFluxes)
                flux = obj.flashFluxes(pulseIdx);
                if isfinite(flux) && flux > 0
                    exponent = floor(log10(abs(flux)));
                    mantissa = flux / 10^exponent;
                    fluxStr = sprintf('%.2fe%+03d ph/cm^2/s', mantissa, exponent);
                end
            end

            if isempty(fluxStr)
                info = sprintf('Current flash: %.2f V  |  NDF %.1f', voltage, ndf);
            else
                info = sprintf('Current flash: %.2f V  |  NDF %.1f  |  %s', voltage, ndf, fluxStr);
            end

            set(obj.flashText, 'String', info);
        end
        
        function updateProgress(obj)
            set(obj.statusText, 'String', [num2str(obj.numEpochsCompleted) ' of ' num2str(obj.totalNumEpochs) ' epochs have completed']);
            
            obj.progressBar.setValue(obj.numEpochsCompleted);
            
            timeLeft = '';
            if ~isempty(obj.averageEpochDuration) && ~isempty(obj.averageIntervalDuration)
                n = obj.totalNumEpochs - obj.numEpochsCompleted;
                d = obj.averageEpochDuration * n;
                if n > 0
                    d = d + obj.averageIntervalDuration * n;
                end
                [h, m, s] = hms(d);
                if h >= 1
                    timeLeft = sprintf('%.0f hours, %.0f minutes', h, m);
                elseif m >= 1
                    timeLeft = sprintf('%.0f minutes, %.0f seconds', m, s);
                else
                    timeLeft = sprintf('%.0f seconds', s);
                end
            end
            set(obj.timeText, 'String', sprintf('Estimated time left: %s', timeLeft));
        end
        
    end
    
end
