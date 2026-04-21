classdef CfMeaLedSine < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents a sinusoidal light stimulus on a specified LED and a scaled
    % copy to the amplifier DAC for MCS MEA integration.

    properties
        led                             % Output LED
        amp                             % Output amplifier
        preTime = 50                    % Leading duration (ms)
        stimTime = 5000                 % Stimulus duration (ms)
        tailTime = 5000                 % Trailing duration (ms)
        lightMean = 5                   % LED mean voltage (V [0-10])
        lightAmplitude = 5              % LED sine amplitude (voltage deviation from mean)
        frequency = 1                   % Stimulus frequency (Hz)
        phase = 0                       % Sine wave phase offset (radians)
        ndf = 0.0                       % ND filter setting (applied to filter wheel at run start)
        numberOfAverages = uint16(5)    % Number of epochs
        interpulseInterval = 0          % Duration between pulses (s)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
        period                          % Sine period (ms), calculated from frequency
        MEA_mean                        % Mean voltage output to MCS (auto-calculated)
        MEA_amp                         % Amp voltage output to MCS (auto-calculated)
        photonFluxBackground            % Estimated photon flux at mean voltage (photons/cm2/s)
    end

    properties (Dependent)
        photonFluxPeak                  % Peak photon flux (photons/cm2/s). Accepts scientific notation, e.g. '1.5e15'.
    end

    properties (Hidden)
        ledType
        ampType
    end

    methods

        % MEA scaling: 50 mV command -> 1 mV step; max MEA input 4 V (factor of 8).
        function v = get.MEA_mean(obj)
            v = obj.lightMean * 1000 * 0.4 / 50;
        end

        function v = get.MEA_amp(obj)
            v = obj.lightAmplitude * 1000 * 0.4 / 50;
        end

        function p = get.period(obj)
            p = 1000 / obj.frequency;
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

            % Constrain the ndf field to valid filter wheel values.
            if strcmp(name, 'ndf')
                d.type = symphonyui.core.PropertyType('denserealdouble', 'scalar', ...
                    {0, 0.5, 1.0, 2.0, 3.0, 4.0});
            end

            % Treat photonFluxPeak as an editable string so scientific
            % notation input (e.g. "1.5e15") is accepted and displayed.
            if strcmp(name, 'photonFluxPeak')
                d.type = symphonyui.core.PropertyType('char', 'row');
            end
        end

        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()obj.createLedStimulus());
        end

        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);

            obj.showFigure('fortenbachlab.figures.ProgressFigure', obj.numberOfAverages);
            obj.setLedBackground(obj.rig.getDevice(obj.led), obj.lightMean);

            % Move the filter wheel to the selected NDF; wait ~4 s for
            % the wheel to settle if it actually moves.
            try
                fws = obj.rig.getDevices('FilterWheel');
                if ~isempty(fws)
                    try
                        currentNDF = fws{1}.getConfigurationSetting('NDF');
                    catch
                        currentNDF = [];
                    end
                    fws{1}.setNDF(obj.ndf);
                    if ~isempty(currentNDF) && ~isequal(currentNDF, obj.ndf)
                        pause(4);
                    end
                end
            catch e
                warning('CfMeaLedSine:setNDFFailed', ...
                    'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
            end
        end

        function LEDstim = createLedStimulus(obj)
            gen = symphonyui.builtin.stimuli.SineGenerator();
            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.mean = obj.lightMean;
            gen.period = obj.period;
            gen.phase = obj.phase;
            gen.sampleRate = obj.sampleRate;
            gen.amplitude = obj.lightAmplitude;
            gen.units = obj.rig.getDevice(obj.led).background.displayUnits;

            LEDstim = gen.generate();
        end

        function Ampstim = createAmpStimulus(obj, ndf)
            ampDevice = obj.rig.getDevice(obj.amp);
            background = ampDevice.background.quantity;
            units = ampDevice.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            prePts  = timeToPts(obj.preTime);
            stimPts = timeToPts(obj.stimTime);
            tailPts = timeToPts(obj.tailTime);

            % Build base waveform: MEA-scaled mean + sine during stimTime.
            data = ones(1, prePts + stimPts + tailPts) * obj.MEA_mean;
            t = (0:stimPts-1) / obj.sampleRate;  % seconds
            sineWave = obj.MEA_amp * sin(2*pi * obj.frequency * t + obj.phase);
            data(prePts+1 : prePts+stimPts) = obj.MEA_mean + sineWave;

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

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            % Record photon flux and NDF to epoch metadata.
            ndf = obj.ndf;

            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
            epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpStimulus(ndf));
            epoch.addResponse(obj.rig.getDevice(obj.amp));
            epoch.addParameter('ndf', ndf);
            epoch.addParameter('photonFluxPeak', obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, ndf));
            epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, ndf));

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
            tf = obj.numEpochsPrepared < obj.numberOfAverages;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
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

        function s = get.photonFluxPeak(obj)
            % Return the peak flux as a scientific-notation string.
            try
                f = obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, obj.ndf);
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

        function set.photonFluxPeak(obj, val)
            % Parse the user-entered string (scientific notation OK, e.g.
            % '1.5e15', '1.5E+15', '2.55e+16 photons/cm2/s') and invert
            % the calibration to find the required total LED voltage at
            % the current NDF, then update lightAmplitude so that
            % lightMean + lightAmplitude matches the target.
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
                warning('CfMeaLedSine:NoCalibration', ...
                    'LED calibration not loaded; cannot set photonFluxPeak.');
                return;
            end
            vPeak = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf);
            if isnan(vPeak)
                vPeak = 10;  % clamp to max
            end
            newAmplitude = vPeak - obj.lightMean;
            if newAmplitude < 0
                newAmplitude = 0;
            end
            obj.lightAmplitude = newAmplitude;
        end

        function s = get.photonFluxBackground(obj)
            try
                ndf = obj.ndf;
                s = obj.getPhotonFluxString(obj.lightMean, ndf);
            catch
                s = 'N/A';
            end
        end

    end

end
