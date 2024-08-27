classdef CFMEALedPulseFamily < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents families of rectangular pulse stimuli to a specified LED and records responses from a specified 
    % amplifier. Each family consists of a set of pulse stimuli with amplitude starting at firstLightAmplitude. With
    % each subsequent pulse in the family, the amplitude is doubled. The family is complete when this sequence has been
    % executed pulsesInFamily times.
    %
    % For example, with values firstLightAmplitude = 0.1 and pulsesInFamily = 3, the sequence of pulse stimuli amplitude
    % values in each family would be: 0.1 then 0.2 then 0.4.
    
    properties
        led                             % Output LED
        amp                             % Output amplifier
        preTime = 10                    % Pulse leading duration (ms)
        stimTime = 100                  % Pulse duration (ms)
        tailTime = 400                  % Pulse trailing duration (ms)
        firstLightAmplitude = 1         % First pulse amplitude (V [0-10])
        pulsesInFamily = uint16(3)      % Number of pulses in family
        firstPulseAmplitude = 1              % Voltage Output (Auto-calculated DO NOT ADJUST to avoid MEA overload)
        lightMean = 0                   % Pulse and LED background mean (V or norm. [0-1] depending on LED units)
    end
    
    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
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
        
% When delivering voltage steps, 50 mV command results in 1 mV voltage step and max input voltage of MEA is 4 volts and 
    function pulseAmplitudeCut = get.pulseAmplitude(obj)
        pulseAmplitudeCut = obj.FirstLightAmplitude * 1000 * 0.4 / 50; 
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
        end
        
        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()obj.createLedStimulus());
            function s = createPreviewStimuli(obj)
                s = cell(1, obj.pulsesInFamily);
                for i = 1:numel(s)
                    s{i} = obj.createLedStimulus(i);
                end
            end
        end
        
        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);
            
            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
                obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp))...
                    'groupBy', {'lightAmplitude'});
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2)), ...
                    'groupBy1', {'lightAmplitude'}, ...
                    'groupBy2', {'lightAmplitude'});
                obj.showFigure('fortenbachlab.figures.DualResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, obj.rig.getDevice(obj.amp2), {@mean, @var}, ...
                    'baselineRegion1', [0 obj.preTime], ...
                    'measurementRegion1', [obj.preTime obj.preTime+obj.stimTime], ...
                    'baselineRegion2', [0 obj.preTime], ...
                    'measurementRegion2', [obj.preTime obj.preTime+obj.stimTime]);
            end
            
            device = obj.rig.getDevice(obj.led);
            device.background = symphonyui.core.Measurement(obj.lightMean, device.background.displayUnits);
        end
        
        function [LEDstim, lightAmplitude] = createLedStimulus(obj, pulseNum)
            lightAmplitude = obj.amplitudeForPulseNum(pulseNum);
            
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
        
        function [Ampstim, ampAmplitude] = createAmpStimulus(obj, pulseNum)
            ampAmplitude = obj.amplitudeForPulseNum(pulseNum);
            
            gen = symphonyui.builtin.stimuli.PulseGenerator();
            
            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.amplitude = obj.pulseAmplitude;
            gen.mean = obj.rig.getDevice(obj.amp).background.quantity;
            gen.sampleRate = obj.sampleRate;
            gen.units = obj.rig.getDevice(obj.amp).background.displayUnits;
            
            Ampstim = gen.generate();
        end

        function a = amplitudeForPulseNum(obj, pulseNum)
            a = obj.firstLightAmplitude * 2^(double(pulseNum) - 1);
        end

        function b = amplitudeForPulseNum(obj, pulseNum)
            b = obj.firstPulseAmplitude * 2^(double(pulseNum) - 1);
        end        

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
            
            pulseNum = mod(obj.numEpochsPrepared - 1, obj.pulsesInFamily) + 1;
            [LEDstim, lightAmplitude] = obj.createLedStimulus(pulseNum);
            [Ampstim, ampAmplitude] = obj.createAmpStimulus(pulseNum);

            epoch.addParameter('lightAmplitude', lightAmplitude);
            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
            epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpStimulus());
            epoch.addResponse(obj.rig.getDevice(obj.amp));
            
            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end
        
        function updateLedPulseFigure(obj, epoch)
            
        end
        
        function updateRodFlashFigure(obj, epoch)
            
        end

        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);
            
            device = obj.rig.getDevice(obj.led);
            device = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(device, device.background, obj.interpulseInterval, obj.sampleRate);
        end
        
        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages * obj.pulsesInFamily;
        end
        
        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages * obj.pulsesInFamily;
        end

        function [tf, msg] = isValid(obj)
            [tf, msg] = isValid@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);
            if tf
                units = obj.rig.getDevice(obj.led).background.displayUnits;
                amplitude = obj.amplitudeForPulseNum(obj.pulsesInFamily);
                if (strcmp(units, symphonyui.core.Measurement.NORMALIZED) && amplitude > 1) ...
                        || (strcmp(units, 'V') && amplitude > 10.239)
                    tf = false;
                    msg = 'Last pulse amplitude too large';
                end
            end
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
        
    end
    
end

