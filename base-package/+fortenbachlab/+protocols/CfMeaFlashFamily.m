classdef CfMeaFlashFamily < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents families of rectangular pulse stimuli to a specified LED and records responses from a specified
    % amplifier. Each family consists of a set of pulse stimuli with amplitude starting at firstLightAmplitude. With
    % each subsequent pulse in the family, the amplitude is doubled. The family is complete when this sequence has been
    % executed pulsesInFamily times.
    %
    % When autoNDF is enabled, the protocol works in photon-flux space.
    % Intensity doubles each step; when the voltage required to deliver
    % the target flux exceeds 10 V at the current NDF, the filter wheel
    % automatically advances to the next lower NDF (more light) and the
    % voltage is recomputed via the calibration curve.
    %
    % Example (autoNDF on, startingNDF = 4.0, firstLightAmplitude = 1 V):
    %   Pulse 1: 1 V   @ NDF 4.0  ->  flux_1
    %   Pulse 2: 2 V   @ NDF 4.0  ->  flux_2  = 2 * flux_1
    %   ...until voltage would exceed 10 V, then NDF steps down.

    properties
        led                             % Output LED
        amp                             % Output amplifier
        preTime = 50                    % Pulse leading duration (ms)
        stimTime = 5000                 % Pulse duration (ms)
        tailTime = 5000                 % Pulse trailing duration (ms)
        firstLightAmplitude = 1         % First pulse amplitude (V [0-10])
        pulsesInFamily = uint16(3)      % Number of pulses in family
        lightMean = 0                   % Pulse and LED background mean (V or norm. [0-1] depending on LED units)
        autoNDF = false                 % Automatically switch NDF when voltage exceeds 10 V
        startingNDF = 4.0               % Starting NDF value (used when autoNDF is true)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
        firstPulseAmplitude             % Scaled voltage output to MCS (auto-calculated)
        photonFluxPeakMax               % Photon flux at last (brightest) pulse (photons/cm2/s)
        photonFluxBackground            % Estimated photon flux at lightMean (photons/cm2/s)
    end

    properties (Dependent)
        photonFluxPeakMin               % Photon flux at first (dimmest) pulse. Accepts scientific notation, e.g. '1.5e15'.
    end

    properties
        numberOfAverages = uint16(5)    % Number of epochs
        interpulseInterval = 0          % Duration between pulses (s)
    end

    properties (Hidden)
        ledType
        ampType
        startingNDFType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
    end

    properties (Constant, Hidden)
        NDF_VALUES = [0 0.5 1.0 2.0 3.0 4.0];  % Available NDF positions (ascending)
    end

    methods

    % When delivering voltage steps, 50 mV command results in 1 mV voltage step and max input voltage of MEA is 4 volts.
    function pulseAmplitudeCut = get.firstPulseAmplitude(obj)
        pulseAmplitudeCut = obj.firstLightAmplitude * 1000 * 0.4 / 50;
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

            % Hide startingNDF when autoNDF is off.
            if strcmp(name, 'startingNDF') && ~obj.autoNDF
                d.isHidden = true;
            end

            % Treat photonFluxPeakMin as an editable string so scientific
            % notation input (e.g. "1.5e15") is accepted and displayed.
            if strcmp(name, 'photonFluxPeakMin')
                d.type = symphonyui.core.PropertyType('char', 'row');
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()createPreviewStimuli(obj));
            function s = createPreviewStimuli(obj)
                s = cell(1, obj.pulsesInFamily);
                for i = 1:numel(s)
                    [s{i}, ~] = obj.createLedStimulus(i);
                end
            end
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
                obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp), ...
                    'groupBy', {'lightAmplitude'});
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2), ...
                    'groupBy1', {'lightAmplitude'}, ...
                    'groupBy2', {'lightAmplitude'});
                obj.showFigure('fortenbachlab.figures.DualResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, obj.rig.getDevice(obj.amp2), {@mean, @var}, ...
                    'baselineRegion1', [0 obj.preTime], ...
                    'measurementRegion1', [obj.preTime obj.preTime+obj.stimTime], ...
                    'baselineRegion2', [0 obj.preTime], ...
                    'measurementRegion2', [obj.preTime obj.preTime+obj.stimTime]);
            end

            % If autoNDF, set the filter wheel to the starting NDF before
            % the first epoch and set background at that NDF.
            if obj.autoNDF
                obj.setFilterWheelNDF(obj.startingNDF);
            end

            obj.setLedBackground(obj.led, obj.lightMean);

            obj.showFigure('fortenbachlab.figures.ProgressFigure', obj.numberOfAverages * obj.pulsesInFamily);
        end

        % ------------------------------------------------------------------
        %  Compute the (voltage, NDF) pair for each pulse in the family.
        % ------------------------------------------------------------------

        function [voltages, ndfs, fluxes] = computePulseTable(obj)
            % COMPUTEPULSETABLE  Pre-compute voltage, NDF, and photon flux
            % for every pulse in the family.
            %
            %   [voltages, ndfs, fluxes] = computePulseTable(obj)
            %
            % When autoNDF is false the behaviour is the same as before:
            % voltage doubles each step at whatever NDF the wheel is set to.
            %
            % When autoNDF is true:
            %   1. The first pulse is firstLightAmplitude at startingNDF.
            %   2. The target flux doubles each step.
            %   3. If the voltage required exceeds 10 V at the current NDF,
            %      the NDF steps down (less attenuation) and the voltage is
            %      recomputed from the calibration curve.

            n = double(obj.pulsesInFamily);
            voltages = zeros(1, n);
            ndfs     = zeros(1, n);
            fluxes   = zeros(1, n);

            obj.ensureCalibrationLoaded();

            if ~obj.autoNDF || isempty(obj.ledCalibration)
                % --- Legacy behaviour: simple voltage doubling --------
                ndf = obj.getCurrentNDF();
                for i = 1:n
                    v = obj.firstLightAmplitude * 2^(i - 1);
                    voltages(i) = v;
                    ndfs(i) = ndf;
                    if ~isempty(obj.ledCalibration)
                        fluxes(i) = obj.ledCalibration.voltageToFlux(obj.lightMean + v, ndf);
                    end
                end
                return;
            end

            % --- Auto-NDF: work in flux space -------------------------
            % fluxToVoltage returns the TOTAL DAQ voltage for a target
            % flux.  The PulseGenerator adds amplitude to mean, so the
            % amplitude we store is  totalVoltage - lightMean.
            cal = obj.ledCalibration;
            currentNdf = obj.startingNDF;

            % First pulse: use firstLightAmplitude at startingNDF.
            peakVoltage1 = obj.lightMean + obj.firstLightAmplitude;
            firstFlux = cal.voltageToFlux(peakVoltage1, currentNdf);
            voltages(1) = obj.firstLightAmplitude;   % amplitude, not total
            ndfs(1)     = currentNdf;
            fluxes(1)   = firstFlux;

            for i = 2:n
                % Double the target peak flux.
                targetFlux = firstFlux * 2^(i - 1);

                % fluxToVoltage returns the total DAQ voltage for targetFlux.
                vTotal = cal.fluxToVoltage(targetFlux, currentNdf);

                if isnan(vTotal) || vTotal > 10.239
                    % Need to step down to a lower NDF (more light).
                    stepped = false;
                    ndfIdx = find(obj.NDF_VALUES == currentNdf, 1);
                    while ndfIdx > 1
                        ndfIdx = ndfIdx - 1;
                        candidateNdf = obj.NDF_VALUES(ndfIdx);
                        vTotal = cal.fluxToVoltage(targetFlux, candidateNdf);
                        if ~isnan(vTotal) && vTotal <= 10.239
                            currentNdf = candidateNdf;
                            stepped = true;
                            break;
                        end
                    end
                    if ~stepped
                        % Even NDF 0 can't deliver this flux. Clip to max.
                        currentNdf = 0;
                        vTotal = 10.239;
                    end
                end

                amplitude = max(0, vTotal - obj.lightMean);
                voltages(i) = amplitude;
                ndfs(i)     = currentNdf;
                fluxes(i)   = cal.voltageToFlux(vTotal, currentNdf);
            end
        end

        % ------------------------------------------------------------------
        %  Stimulus creation
        % ------------------------------------------------------------------

        function [LEDstim, lightAmplitude] = createLedStimulus(obj, pulseNum)
            if obj.autoNDF && ~isempty(obj.ledCalibration)
                [voltages, ~, ~] = obj.computePulseTable();
                lightAmplitude = voltages(pulseNum);
            else
                lightAmplitude = obj.LEDamplitudeForPulseNum(pulseNum);
            end

            gen = symphonyui.builtin.stimuli.PulseGenerator();

            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.amplitude = lightAmplitude;
            gen.mean = obj.lightMean;
            gen.sampleRate = obj.sampleRate;
            gen.units = obj.rig.getDevice(obj.led).background.displayUnits;

            LEDstim = gen.generate();
        end

        function [Ampstim, ampAmplitude] = createAmpStimulus(obj, pulseNum, ndf)
            ampAmplitude = obj.PulseamplitudeForPulseNum(pulseNum);
            ampDevice = obj.rig.getDevice(obj.amp);
            background = ampDevice.background.quantity;
            units = ampDevice.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            prePts  = timeToPts(obj.preTime);
            stimPts = timeToPts(obj.stimTime);
            tailPts = timeToPts(obj.tailTime);

            % Build base waveform: background + scaled pulse.
            data = ones(1, prePts + stimPts + tailPts) * background;
            data(prePts+1 : prePts+stimPts) = background + ampAmplitude;

            % NDF encoding: three 10-ms pulses [marker, NDF, marker] scaled
            % by the same ×8 MEA factor used for the stimulus amplitude.
            % Marker value of 1 V → 8 V on MCS (within DAC range).
            meaScale = 1000 * 0.4 / 50;
            pulsePts = timeToPts(10);  % 10 ms per step
            gapPts  = timeToPts(5);   % 5 ms blank between steps
            idx = 1;
            data(idx : idx+pulsePts-1)           = 1   * meaScale;  idx = idx + pulsePts + gapPts;
            data(idx : idx+pulsePts-1)           = ndf * meaScale;  idx = idx + pulsePts + gapPts;
            data(idx : idx+pulsePts-1)           = 1   * meaScale;

            Ampstim = obj.createStimulusFromArray(data, units);
        end

        function a = LEDamplitudeForPulseNum(obj, pulseNum)
            a = obj.firstLightAmplitude * 2^(double(pulseNum) - 1);
        end

        function b = PulseamplitudeForPulseNum(obj, pulseNum)
            b = obj.firstPulseAmplitude * 2^(double(pulseNum) - 1);
        end

        % ------------------------------------------------------------------
        %  Filter wheel helper
        % ------------------------------------------------------------------

        function setFilterWheelNDF(obj, ndf)
            % Set the filter wheel to the specified NDF value. Blocks for
            % ~4 seconds if the wheel actually needs to move, so the
            % filter is in place before the next epoch starts.
            try
                devices = obj.rig.getDevices('FilterWheel');
                if isempty(devices)
                    return;
                end
                try
                    currentNDF = devices{1}.getConfigurationSetting('NDF');
                catch
                    currentNDF = [];
                end
                devices{1}.setNDF(ndf);
                if ~isempty(currentNDF) && ~isequal(currentNDF, ndf)
                    pause(4);
                end
            catch e
                disp(['FilterWheel command failed: ' e.message]);
            end
        end

        % ------------------------------------------------------------------
        %  Epoch lifecycle
        % ------------------------------------------------------------------

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            pulseNum = mod(obj.numEpochsPrepared - 1, obj.pulsesInFamily) + 1;

            if obj.autoNDF && ~isempty(obj.ledCalibration)
                [voltages, ndfs, fluxes] = obj.computePulseTable();
                lightAmplitude = voltages(pulseNum);
                ndf = ndfs(pulseNum);

                % Switch the filter wheel if NDF changed from previous pulse.
                % setFilterWheelNDF now blocks for ~4 s when the wheel
                % actually moves, so no extra pause is needed here.
                if pulseNum == 1 || ndfs(pulseNum) ~= ndfs(max(1, pulseNum - 1))
                    obj.setFilterWheelNDF(ndf);
                end

                [LEDstim, ~] = obj.createLedStimulus(pulseNum);
                [Ampstim, ~] = obj.createAmpStimulus(pulseNum, ndf);

                epoch.addParameter('lightAmplitude', lightAmplitude);
                epoch.addParameter('ndf', ndf);
                epoch.addParameter('photonFluxPeak', fluxes(pulseNum));
                epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, ndf));
            else
                ndf = obj.getCurrentNDF();
                [LEDstim, lightAmplitude] = obj.createLedStimulus(pulseNum);
                [Ampstim, ~] = obj.createAmpStimulus(pulseNum, ndf);

                epoch.addParameter('lightAmplitude', lightAmplitude);
                epoch.addParameter('ndf', ndf);
                epoch.addParameter('photonFluxPeak', obj.getPhotonFlux(obj.lightMean + lightAmplitude, ndf));
                epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, ndf));
            end

            epoch.addStimulus(obj.rig.getDevice(obj.led), LEDstim);
            epoch.addStimulus(obj.rig.getDevice(obj.amp), Ampstim);
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);

            % Hold LED at background during inter-pulse interval.
            ledDevice = obj.rig.getDevice(obj.led);
            interval.addDirectCurrentStimulus(ledDevice, ledDevice.background, obj.interpulseInterval, obj.sampleRate);

            % Hold amplifier at background during inter-pulse interval.
            ampDevice = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(ampDevice, ampDevice.background, obj.interpulseInterval, obj.sampleRate);
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function [tf, msg] = isValid(obj)
            [tf, msg] = isValid@fortenbachlab.protocols.FortenbachLabProtocol(obj);
            if tf && ~obj.autoNDF
                % Legacy check: ensure the last pulse doesn't overflow.
                units = obj.rig.getDevice(obj.led).background.displayUnits;
                amplitude = obj.LEDamplitudeForPulseNum(obj.pulsesInFamily);
                if (strcmp(units, symphonyui.core.Measurement.NORMALIZED) && amplitude > 1) ...
                        || (strcmp(units, 'V') && amplitude > 10.239)
                    tf = false;
                    msg = 'Last pulse amplitude too large';
                end
            end
            % When autoNDF is on, overflow is handled by NDF stepping.
        end

        % ------------------------------------------------------------------
        %  Dependent property getters
        % ------------------------------------------------------------------

        function a = get.amp2(obj)
            amps = obj.rig.getDeviceNames('Amp');
            if numel(amps) < 2
                a = '(None)';
            else
                i = find(~ismember(amps, obj.amp), 1);
                a = amps{i};
            end
        end

        function s = get.photonFluxPeakMin(obj)
            % Photon flux at the first (dimmest) pulse.
            try
                [voltages, ndfs, fluxes] = obj.computePulseTable();
                f = fluxes(1);
                if f == 0
                    fStr = '0';
                else
                    exponent = floor(log10(abs(f)));
                    mantissa = f / 10^exponent;
                    fStr = sprintf('%.2fe%+03d', mantissa, exponent);
                end
                s = sprintf('%s ph/cm2/s  (%.2fV, NDF %.1f)', fStr, voltages(1), ndfs(1));
            catch
                s = 'N/A';
            end
        end

        function set.photonFluxPeakMin(obj, val)
            % Parse a scientific-notation string (or number) and invert
            % the calibration to find the LED voltage needed to deliver
            % that flux for the first pulse. Sets firstLightAmplitude
            % accordingly; subsequent pulses in the family still follow
            % the doubling / auto-NDF logic.
            %
            % The NDF used for the inversion is startingNDF when autoNDF
            % is on, otherwise the current filter-wheel NDF.
            if isnumeric(val)
                targetFlux = double(val);
            elseif ischar(val) || isstring(val)
                str = strtrim(char(val));
                tok = regexp(str, '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?', 'match', 'once');
                if isempty(tok)
                    return;
                end
                targetFlux = str2double(tok);
            else
                return;
            end
            if isempty(targetFlux) || ~isfinite(targetFlux) || targetFlux < 0
                return;
            end
            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration)
                warning('CfMeaFlashFamily:NoCalibration', ...
                    'LED calibration not loaded; cannot set photonFluxPeakMin.');
                return;
            end
            if obj.autoNDF
                ndf = obj.startingNDF;
            else
                ndf = obj.getCurrentNDF();
            end
            vPeak = obj.ledCalibration.fluxToVoltage(targetFlux, ndf);
            if isnan(vPeak)
                vPeak = 10;  % clamp to max
            end
            newAmplitude = vPeak - obj.lightMean;
            if newAmplitude < 0
                newAmplitude = 0;
            end
            obj.firstLightAmplitude = newAmplitude;
        end

        function s = get.photonFluxPeakMax(obj)
            % Photon flux at the last (brightest) pulse.
            try
                [voltages, ndfs, fluxes] = obj.computePulseTable();
                f = fluxes(end);
                if f == 0
                    fStr = '0';
                else
                    exponent = floor(log10(abs(f)));
                    mantissa = f / 10^exponent;
                    fStr = sprintf('%.2fe%+03d', mantissa, exponent);
                end
                s = sprintf('%s ph/cm2/s  (%.2fV, NDF %.1f)', fStr, voltages(end), ndfs(end));
            catch
                s = 'N/A';
            end
        end

        function s = get.photonFluxBackground(obj)
            try
                if obj.autoNDF
                    ndf = obj.startingNDF;
                else
                    ndf = obj.getCurrentNDF();
                end
                s = obj.getPhotonFluxString(obj.lightMean, ndf);
            catch
                s = 'N/A';
            end
        end

    end

end
