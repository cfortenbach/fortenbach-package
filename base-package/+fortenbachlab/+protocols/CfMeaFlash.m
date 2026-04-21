classdef CfMeaFlash < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents a set of rectangular pulse stimuli to a specified LED and records from a specified amplifier.
    
    properties
        led                             % Output LED
        amp                             % Output amplifier
        preTime = 50                    % Pulse leading duration (ms)
        stimTime = 5000                 % Pulse duration (ms)
        tailTime = 5000                 % Pulse trailing duration (ms)
        lightAmplitude = 1              % Pulse amplitude (V [0-10])
        pulseAmplitude = 1              % Voltage Output (Auto-calculated DO NOT ADJUST to avoid MEA overload)
        lightMean = 0                   % Pulse and LED background mean (V or norm. [0-1] depending on LED units)
        ndf = 0.0                       % ND filter setting (applied to filter wheel at run start)
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
        photonFluxBackground            % Estimated photon flux at lightMean (photons/cm2/s)
    end

    properties (Dependent)
        photonFluxPeak                  % Peak photon flux (photons/cm2/s). Accepts scientific notation, e.g. '1.5e15'.
    end

    properties
        numberOfAverages = uint16(5)    % Number of epochs
        interpulseInterval = 0          % Duration between pulses (s)
    end

    properties (Hidden)
        ledType
        ampType
    end
    
    methods
        
        % When delivering voltage steps, 50 mV command results in 1 mV voltage step and max input voltage of MEA is 4 volts.
        function pulseAmplitudeCut = get.pulseAmplitude(obj)
            pulseAmplitudeCut = obj.lightAmplitude * 1000 * 0.4 / 50;
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
            
%            if numel(obj.rig.getDeviceNames('Amp')) < 2
%                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
%                obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp));
%                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
%                    'baselineRegion', [0 obj.preTime], ...
%                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
%            else
%                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
%                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
%                obj.showFigure('fortenbachlab.figures.DualResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, obj.rig.getDevice(obj.amp2), {@mean, @var}, ...
%                    'baselineRegion1', [0 obj.preTime], ...
%                    'measurementRegion1', [obj.preTime obj.preTime+obj.stimTime], ...
%                    'baselineRegion2', [0 obj.preTime], ...
%                    'measurementRegion2', [obj.preTime obj.preTime+obj.stimTime]);
%            end
            
            obj.setLedBackground(obj.led, obj.lightMean);

            % Move the filter wheel to the selected NDF. If the NDF is
            % actually changing, wait for the wheel to physically settle
            % before starting any epochs.
            try
                fws = obj.rig.getDevices('FilterWheel');
                if ~isempty(fws)
                    currentNDF = fws{1}.getConfigurationSetting('NDF');
                    fws{1}.setNDF(obj.ndf);
                    if ~isequal(currentNDF, obj.ndf)
                        pause(4);  % filter wheel settle time
                    end
                end
            catch e
                warning('CfMeaFlash:setNDFFailed', ...
                    'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
            end

            obj.showFigure('fortenbachlab.figures.ProgressFigure', obj.numberOfAverages);
        end
        
        function LEDstim = createLedStimulus(obj)
            gen = symphonyui.builtin.stimuli.PulseGenerator();
            
            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.amplitude = obj.lightAmplitude;
            gen.mean = obj.lightMean;
            gen.sampleRate = obj.sampleRate;
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

            % Build base waveform: background + scaled pulse.
            data = ones(1, prePts + stimPts + tailPts) * background;
            data(prePts+1 : prePts+stimPts) = background + obj.pulseAmplitude;

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
                if isempty(f) || ~isfinite(f)
                    s = '0';
                elseif f == 0
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
            % the calibration to find the required LED voltage at the
            % current NDF, then update lightAmplitude.
            if isnumeric(val)
                targetFlux = double(val);
            elseif ischar(val) || isstring(val)
                str = strtrim(char(val));
                % Strip any trailing unit text.
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
                warning('CfMeaFlash:NoCalibration', ...
                    'LED calibration not loaded; cannot set photonFluxPeak.');
                return;
            end
            % Compute voltage at the light peak (background + amplitude).
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

