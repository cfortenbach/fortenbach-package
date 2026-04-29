classdef CfPatchFlash < fortenbachlab.protocols.FortenbachLabProtocol
    % Presents a set of rectangular pulse stimuli to a specified LED and records from a specified amplifier.
    
    properties
        led                             % Output LED
        preTime = 50                    % Pulse leading duration (ms)
        stimTime = 10                   % Pulse duration (ms)
        tailTime = 3000                 % Pulse trailing duration (ms)
        lightAmplitude = 5              % Pulse amplitude (V or norm. [0-1] depending on LED units)
        lightMean = 0                   % Pulse and LED background mean (V or norm. [0-1] depending on LED units)
        ndf = 0.0                       % ND filter setting
        numberOfAverages = uint16(5)    % Number of epochs
        interpulseInterval = 0          % Duration between pulses (s)
        amp                             % Input amplifier
    end

    properties (Dependent, SetAccess = private)
        amp2                            % Secondary amplifier
    end

    properties (Dependent)
        photonFluxPeak                  % Estimated photon flux at peak (photons/cm2/s). Accepts scientific notation.
        photonFluxBackground            % Estimated photon flux at background (photons/cm2/s). Accepts scientific notation.
    end

    properties
        showOnsetFigure = true          % Show zoomed flash onset figure
        onsetPrePad = 5                 % Flash onset window: ms before onset
        onsetPostPad = 100              % Flash onset window: ms after onset
    end

    properties (Hidden)
        ledType
        ampType
        ndfType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {0, 0.5, 1.0, 2.0, 3.0, 4.0})
    end
    
    methods
        
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

            % Treat photon flux fields as editable strings so scientific
            % notation input (e.g. "1.5e15") is accepted and displayed.
            if strcmp(name, 'photonFluxPeak') || strcmp(name, 'photonFluxBackground')
                d.type = symphonyui.core.PropertyType('char', 'row');
            end
        end
        
        function p = getPreview(obj, panel)
            p = symphonyui.builtin.previews.StimuliPreview(panel, @()obj.createLedStimulus());
        end
        
        function prepareRun(obj)
            prepareRun@fortenbachlab.protocols.FortenbachLabProtocol(obj);
            
            if numel(obj.rig.getDeviceNames('Amp')) < 2
                obj.showFigure('fortenbachlab.figures.ResponseStimulusFigure', ...
                    obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.led));
                obj.showFigure('fortenbachlab.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp), ...
                    'ledDevice', obj.rig.getDevice(obj.led));
                obj.showFigure('symphonyui.builtin.figures.ResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, ...
                    'baselineRegion', [0 obj.preTime], ...
                    'measurementRegion', [obj.preTime obj.preTime+obj.stimTime]);
            else
                obj.showFigure('fortenbachlab.figures.DualResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualMeanResponseFigure', obj.rig.getDevice(obj.amp), obj.rig.getDevice(obj.amp2));
                obj.showFigure('fortenbachlab.figures.DualResponseStatisticsFigure', obj.rig.getDevice(obj.amp), {@mean, @var}, obj.rig.getDevice(obj.amp2), {@mean, @var}, ...
                    'baselineRegion1', [0 obj.preTime], ...
                    'measurementRegion1', [obj.preTime obj.preTime+obj.stimTime], ...
                    'baselineRegion2', [0 obj.preTime], ...
                    'measurementRegion2', [obj.preTime obj.preTime+obj.stimTime]);
            end
            
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
                warning('CfPatchFlash:setNDFFailed', ...
                    'Failed to set filter wheel to NDF %g: %s', obj.ndf, e.message);
            end

            obj.setLedBackground(obj.led, obj.lightMean);

            if obj.cellHealthEnabled()
                obj.showFigure('fortenbachlab.figures.CellHealthFigure', obj.rig.getDevice(obj.amp));
            else
                obj.warnCellHealthDisabled();
            end

            if obj.showOnsetFigure
                obj.showFigure('fortenbachlab.figures.FlashOnsetFigure', obj.rig.getDevice(obj.amp), ...
                    'preTime', obj.preTime, ...
                    'prePad', obj.onsetPrePad, ...
                    'postPad', obj.onsetPostPad, ...
                    'ledDevice', obj.rig.getDevice(obj.led));
            end

            obj.showFigure('fortenbachlab.figures.ProgressFigure', obj.numberOfAverages, ...
                'flashVoltages', obj.lightAmplitude, ...
                'flashNdfs', obj.ndf, ...
                'flashFluxes', obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, obj.ndf));
        end
        
        function stim = createLedStimulus(obj)
            gen = symphonyui.builtin.stimuli.PulseGenerator();
            
            gen.preTime = obj.preTime;
            gen.stimTime = obj.stimTime;
            gen.tailTime = obj.tailTime;
            gen.amplitude = obj.lightAmplitude;
            gen.mean = obj.lightMean;
            gen.sampleRate = obj.sampleRate;
            gen.units = obj.rig.getDevice(obj.led).background.displayUnits;
            
            stim = gen.generate();
        end
        
        function stim = createAmpTestPulseStimulus(obj)
            % Create a flat amp stimulus at background with a test pulse
            % embedded in pre-time for cell health monitoring.
            device = obj.rig.getDevice(obj.amp);
            bg = device.background.quantity;
            units = device.background.displayUnits;

            timeToPts = @(t)(round(t / 1e3 * obj.sampleRate));
            totalPts = timeToPts(obj.preTime + obj.stimTime + obj.tailTime);
            data = ones(1, totalPts) * bg;
            data = obj.embedTestPulse(data, obj.amp);
            stim = obj.createStimulusFromArray(data, units);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@fortenbachlab.protocols.FortenbachLabProtocol(obj, epoch);

            epoch.addStimulus(obj.rig.getDevice(obj.led), obj.createLedStimulus());
            if obj.cellHealthEnabled()
                epoch.addStimulus(obj.rig.getDevice(obj.amp), obj.createAmpTestPulseStimulus());
            end
            epoch.addResponse(obj.rig.getDevice(obj.amp));

            % Record photon flux and NDF to epoch metadata.
            epoch.addParameter('ndf', obj.ndf);
            epoch.addParameter('photonFluxPeak', obj.getPhotonFlux(obj.lightMean + obj.lightAmplitude, obj.ndf));
            epoch.addParameter('photonFluxBackground', obj.getPhotonFlux(obj.lightMean, obj.ndf));
            
            if numel(obj.rig.getDeviceNames('Amp')) >= 2
                epoch.addResponse(obj.rig.getDevice(obj.amp2));
            end
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

        function set.photonFluxPeak(obj, val)
            % Parse scientific notation (e.g. '1.5e15') and invert the
            % calibration to set lightAmplitude = vPeak - lightMean.
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
                warning('CfPatchFlash:NoCalibration', ...
                    'LED calibration not loaded; cannot set photonFluxPeak.');
                return;
            end
            vPeak = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf);
            if isnan(vPeak), vPeak = 10; end
            newAmplitude = vPeak - obj.lightMean;
            if newAmplitude < 0, newAmplitude = 0; end
            obj.lightAmplitude = newAmplitude;
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
                warning('CfPatchFlash:NoCalibration', ...
                    'LED calibration not loaded; cannot set photonFluxBackground.');
                return;
            end
            vMean = obj.ledCalibration.fluxToVoltage(targetFlux, obj.ndf);
            if isnan(vMean), vMean = 10; end
            if vMean < 0, vMean = 0; end
            obj.lightMean = vMean;
        end

        function s = get.photonFluxPeak(obj)
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