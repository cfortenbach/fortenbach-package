classdef CF_MEA_LED_Sine < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents a set of sine wave stimulus to a specified LED.
    
    properties
        led                             % Output LED
        amp                             % Output amplifier
        preTime = 100                   % Leading duration (ms)
        stimTime = 5000                 % Stimulus duration (ms)
        tailTime = 5000                 % Trailing duration (ms)
        mean = 5                        % Stimulus amplitude (V [0-10])
        amplitude = 5                   % Stimulus amplitude (voltage deviation from mean)
        frequency = 1                   % Stimulus frequency (Hz)
        phase = 0                       % Sine wave phase offset (radians)
        period = 1                      % Will be calculated from frequency          
        MEA_mean = 8                    % Mean Voltage Output to MCS (Auto-calculated DO NOT ADJUST to avoid MEA overload)
        MEA_amp = 8                     % Amp Voltage Output to MCS (Auto-calculated DO NOT ADJUST to avoid MEA overload)

%        units                           % Units of generated stimulus
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
        function MEA_MeanCut = get.MEA_mean(obj)
            MEA_MeanCut = obj.mean * 0.4 / 50; 
        end

        function MEA_AmpCut = get.MEA_amp(obj)
            MEA_AmpCut = obj.amplitude * 0.4 / 50; 
        end
        
        function calcPeriod = get.period(obj)
            calcPeriod = 1000 / obj.frequency; 
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
            
            device = obj.rig.getDevice(obj.led);
        end
        
        function LEDstim = createLedStimulus(obj)
            gen = symphonyui.builtin.stimuli.SineGenerator();
            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.mean = obj.mean;
            gen.period = obj.period;
            gen.phase = obj.phase;
            gen.sampleRate = obj.sampleRate;
            gen.amplitude = obj.amplitude;
            gen.units = obj.rig.getDevice(obj.led).background.displayUnits;
            
            LEDstim = gen.generate();
        end
        
        function Ampstim = createAmpStimulus(obj)
            gen = symphonyui.builtin.stimuli.SineGenerator();
            
            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.mean = obj.MEA_mean;
            gen.period = obj.period;
            gen.phase = obj.phase;
            gen.sampleRate = obj.sampleRate;
            gen.amplitude = obj.MEA_amp;
            gen.units = obj.rig.getDevice(obj.led).background.displayUnits;

            
            Ampstim = gen.generate();
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);
            
            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
            epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpStimulus());
            epoch.addResponse(obj.rig.getDevice(obj.amp));
            
            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
        end
        
        function prepareInterval(obj, interval)
            prepareInterval@fortenbachlab.protocols.FortenbachLabProtocol(obj, interval);
            
            device = obj.rig.getDevice(obj.led);
            device = obj.rig.getDevice(obj.amp);
            interval.addDirectCurrentStimulus(device, device.background, obj.interpulseInterval, obj.sampleRate);
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
        
    end
    
end

