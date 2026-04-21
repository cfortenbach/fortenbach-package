classdef CfPatchLedNoise < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents families of band-limited Gaussian noise stimuli to a specified LED
    % and records from a specified amplifier.
    %
    % Each family consists of noise stimuli with standard deviation starting at
    % startStdv. Each stdv value is repeated repeatsPerStdv times before advancing
    % to the next stdv, which is startStdv * stdvMultiplier^n. The family completes
    % after stdvMultiples levels have been presented.
    %
    % Example: startStdv=0.1, stdvMultiplier=3, stdvMultiples=3, repeatsPerStdv=5
    %   -> stdv sequence: 0.1 (x5), 0.3 (x5), 0.9 (x5)
    %
    % The noise is generated in the frequency domain with a cascaded Butterworth-
    % style lowpass filter at frequencyCutoff Hz, using GaussianNoiseGeneratorV2.
    % Post-smoothed standard deviation matches the requested value.
    %
    % Photon flux (photons/cm2/s) is computed from the calibration data and
    % recorded as epoch parameters along with the noise seed for reproducibility.

    properties
        led                             % Output LED
        preTime = 500                   % Leading duration (ms)
        stimTime = 10000                % Noise duration (ms)
        tailTime = 500                  % Trailing duration (ms)
        frequencyCutoff = 60            % Noise lowpass cutoff frequency (Hz)
        numberOfFilters = 4             % Number of cascaded filter poles
        startStdv = 0.5                 % First noise standard deviation (V)
        stdvMultiplier = 3              % Multiplier between successive stdv levels
        stdvMultiples = uint16(3)       % Number of stdv levels in family
        repeatsPerStdv = uint16(5)      % Repeats at each stdv level
        useRandomSeed = false           % Use a random seed for each stdv level
        lightMean = 5                   % Noise mean / LED background (V)
        ndf = 0.0                       % ND filter setting
        amp                             % Input amplifier
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
        pulsesInFamily                  % Total epochs per family (computed)
    end

    properties (Dependent)
        photonFluxBackground            % Photon flux at lightMean (photons/cm2/s). Accepts scientific notation.
    end

    properties
        numberOfAverages = uint16(1)    % Number of complete families
        interpulseInterval = 0          % Duration between noise epochs (s)
    end

    properties (Hidden)
        ledType
        ampType
        ndfType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
    end

    methods

        function n = get.pulsesInFamily(obj)
            n = obj.stdvMultiples * obj.repeatsPerStdv;
        end

        function didSetRig(obj)
            didSetRig@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            [obj.led, obj.ledType] = obj.createDeviceNamesProperty('LED');
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function d = getPropertyDescriptor(obj, name)
            d = getPropertyDescriptor@fortenbachlab.protocols.FortenbachLabProtocol(obj, name);

            if strncmp(name, 'amp2', 4) && numel(obj.rig.getDeviceNames('Amp')) < 2
                d.isHidden = true;
            end

            % Constrain NDF to valid filter wheel values.
            if strcmp(name, 'ndf')
                d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', ...
                    {0, 0.5, 1.0, 2.0, 3.0, 4.0});
            end

            % Treat photon flux as an editable string so scientific
            % notation input (e.g. "1.5e15") is accepted and displayed.
            if strcmp(name, 'photonFluxBackground')
                d.type = symphonyui.core.PropertyType('char', 'row');
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()createPreviewStimuli(obj));
            function s = createPreviewStimuli(obj)
                s = cell(1, obj.pulsesInFamily);
                for i = 1:numel(s)
                    if ~obj.useRandomSeed
                        seed = 0;
                    elseif mod(i - 1, obj.repeatsPerStdv) == 0
                        seed = RandStream.shuffleSeed;
                    end
                    s{i} = obj.createLedStimulus(i, seed);
                end
            end
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            % Set filter wheel to selected NDF with settle time.
            try
                fws = obj.rig.getDevices('FilterWheel');
                if ~isempty(fws)
                    currentNDF = fws{1}.getConfigurationSetting('NDF');
                    fws{1}.setNDF(obj.ndf);
                    if ~isequal(currentNDF, obj.ndf)
                        pause(4);
                    end
                end
            catch e
                warning('CfPatchLedNoise:setNDFFailed', ...
                    'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
            end

            % Set LED background with ramp-up to avoid onset transients.
            obj.setLedBackground(obj.led, obj.lightMean);

            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
                obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp), ...
                    'groupBy', {'stdv'});
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2), ...
                    'groupBy1', {'stdv'}, ...
                    'groupBy2', {'stdv'});
            end

            if obj.cellHealthEnabled()
                obj.showFigure('fortenbachlab.figures.CellHealthFigure', obj.rig.getDevice(obj.amp));
            else
                obj.warnCellHealthDisabled();
            end

            % Show progress bar.
            obj.showFigure('fortenbachlab.figures.ProgressFigure', obj.numberOfAverages * obj.pulsesInFamily);

            % Show temporal filter figure if available.
            obj.showFigure('fortenbachlab.figures.TemporalNoiseLEDFigure', obj.rig.getDevice(obj.amp), ...
                'preTime', obj.preTime, ...
                'stimTime', obj.stimTime);
        end

        function [stim, stdv, contrast] = createLedStimulus(obj, pulseNum, seed)
            % Compute stdv for this pulse number.
            sdNum = floor((double(pulseNum) - 1) / double(obj.repeatsPerStdv));
            stdv = obj.stdvMultiplier^sdNum * obj.startStdv;

            gen = edu.washington.riekelab.stimuli.GaussianNoiseGeneratorV2();

            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.stDev = stdv;
            gen.freqCutoff = obj.frequencyCutoff;
            gen.numFilters = obj.numberOfFilters;
            gen.mean = obj.lightMean;
            gen.seed = seed;
            gen.sampleRate = obj.sampleRate;
            gen.units = obj.rig.getDevice(obj.led).background.displayUnits;

            % Clip to valid LED voltage range.
            if strcmp(gen.units, symphonyui.core.Measurement.NORMALIZED)
                gen.upperLimit = 1;
                gen.lowerLimit = 0;
            else
                gen.upperLimit = 10.239;
                gen.lowerLimit = 0;
            end

            stim = gen.generate();

            % Compute contrast sequence (stimulus - mean) / mean for the
            % temporal noise figure. Store as epoch parameter.
            contrast = obj.computeContrast(seed, stdv);
        end

        function contrast = computeContrast(obj, seed, stdv)
            % Regenerate the noise to extract the contrast time series.
            % This mirrors the generator logic so the figure can use it.
            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            stimPts = timeToPts(obj.stimTime);

            stream = RandStream('mt19937ar', 'Seed', seed);
            noiseTime = stdv * stream.randn(1, stimPts);

            % Apply the same frequency-domain filter.
            noiseFreq = fft(noiseTime);
            freqStep = obj.sampleRate / stimPts;
            if mod(stimPts, 2) == 0
                frequencies = (0:stimPts / 2) * freqStep;
                oneSidedFilter = 1 ./ (1 + (frequencies / obj.frequencyCutoff) .^ (2 * obj.numberOfFilters));
                filter = [oneSidedFilter fliplr(oneSidedFilter(2:end - 1))];
            else
                frequencies = (0:(stimPts - 1) / 2) * freqStep;
                oneSidedFilter = 1 ./ (1 + (frequencies / obj.frequencyCutoff) .^ (2 * obj.numberOfFilters));
                filter = [oneSidedFilter fliplr(oneSidedFilter(2:end))];
            end
            filterFactor = sqrt(filter(2:end) * filter(2:end)' / (stimPts - 1));
            noiseFreq = noiseFreq .* filter;
            noiseFreq(1) = 0;
            noiseTime = real(ifft(noiseFreq)) / filterFactor;

            % Clip to match generator.
            voltage = noiseTime + obj.lightMean;
            voltage = max(0, min(10.239, voltage));

            % Contrast = (V - mean) / mean.
            if obj.lightMean > 0
                contrast = (voltage - obj.lightMean) / obj.lightMean;
            else
                contrast = voltage;
            end
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            persistent seed;
            if ~obj.useRandomSeed
                seed = 0;
            elseif mod(obj.numEpochsPrepared - 1, obj.repeatsPerStdv) == 0
                seed = RandStream.shuffleSeed;
            end

            pulseNum = mod(obj.numEpochsPrepared - 1, obj.pulsesInFamily) + 1;
            [stim, stdv, contrast] = obj.createLedStimulus(pulseNum, seed);

            epoch.addParameter('stdv', stdv);
            epoch.addParameter('seed', seed);
            epoch.addParameter('contrast', contrast);
            epoch.addStimulus(obj.rig.getDevice(obj.led), stim);
            if obj.cellHealthEnabled()
                epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpTestPulseStimulus());
            end
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            % Record photon flux and NDF to epoch metadata.
            epoch.addParameter('ndf', obj.ndf);
            epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, obj.ndf));

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function stim = createAmpTestPulseStimulus(obj)
            device = obj.rig.getDevice(obj.amp);
            bg = device.background.quantity;
            units = device.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            totalPts = timeToPts(obj.preTime + obj.stimTime + obj.tailTime);
            data = ones(1, totalPts) * bg;
            data = obj.embedTestPulse(data, obj.amp);
            stim = obj.createStimulusFromArray(data, units);
        end

        function completeEpoch(obj, epoch)
            completeEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            if obj.cellHealthEnabled()
                try
                    testAmp = obj.testPulseAmplitude(obj.amp);
                    metrics = obj.computeCellHealthMetrics(epoch, obj.amp, testAmp, 5, 20);
                    obj.saveCellHealthMetrics(epoch, metrics);
                catch
                end
            end
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);

            device = obj.rig.getDevice(obj.led);
            interval.addDirectCurrentStimulus(device, device.background, obj.interpulseInterval, obj.sampleRate);
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages * obj.pulsesInFamily;
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

        function set.photonFluxBackground(obj, val)
            % Parse scientific notation (e.g. '1.5e15') and invert the
            % calibration to set lightMean.
            if isnumeric(val)
                targetFlux = double(val);
            elseif ischar(val) || isstring(val)
                str = strtrim(char(val));
                tok = regexp(str, '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?', 'match', 'once');
                if isempty(tok), return; end
                targetFlux = str2double(tok);
            else
                return;
            end
            if isempty(targetFlux) || ~isfinite(targetFlux) || targetFlux < 0, return; end
            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration)
                warning('CfPatchLedNoise:NoCalibration', ...
                    'LED calibration not loaded; cannot set photonFluxBackground.');
                return;
            end
            vMean = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf);
            if isnan(vMean), vMean = 10; end
            if vMean < 0, vMean = 0; end
            obj.lightMean = vMean;
        end

        function s = get.photonFluxBackground(obj)
            try
                f = obj.getPhotonFlux(obj.lightMean, obj.ndf);
                if isempty(f) || ~isfinite(f) || f == 0
                    s = '0';
                else
                    exponent = floor(log10(abs(f)));
                    mantissa = f / 10^exponent;
                    s = sprintf('%.2fe%+03d', mantissa, exponent);
                end
            catch
                s = 'N/A';
            end
        end

    end

end
