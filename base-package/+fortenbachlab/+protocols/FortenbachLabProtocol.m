classdef (Abstract) FortenbachLabProtocol < symphonyui.core.Protocol

    properties (Constant, Hidden)
        MIN_PRETIME_CELL_HEALTH = 50  % Minimum preTime (ms) required for cell health metrics
    end

    properties (Hidden, SetAccess = private)
        meaFileName
        isMeaRig
        startedRun
    end

    properties (Hidden, Transient)
        ledCalibration  % fortenbachlab.util.LEDCalibration instance (shared)
    end

    methods
        function prepareRun(obj)
            prepareRun@symphonyui.core.Protocol(obj);

            obj.startedRun = false;

            % Initialize the LED calibration object if not already loaded.
            if isempty(obj.ledCalibration)
                try
                    obj.ledCalibration = fortenbachlab.util.LEDCalibration();
                catch
                    % Calibration file not available; leave empty.
                end
            end

            % (Amplifier telegraph parameters are saved per-epoch in
            % prepareEpoch via readMultiClampParameters.)
        end
        
        function prepareEpoch(obj, epoch)
            prepareEpoch@symphonyui.core.Protocol(obj, epoch);

            % Save amplifier telegraph parameters as explicit epoch
            % parameters. Note: Symphony's MultiClampDevice also merges
            % these into the response/stimulus configuration automatically
            % at the .NET level, but saving them as named epoch parameters
            % makes them easier to access during analysis.
            %
            % Raw SI values are saved alongside converted values in
            % standard electrophysiology units (pF, MOhm, Hz).
            try
                amps = obj.rig.getDeviceNames('Amp');
                for k = 1:numel(amps)
                    device = obj.rig.getDevice(amps{k});
                    prefix = amps{k};  % e.g. 'Amp1'
                    try
                        params = obj.readMultiClampParameters(device);

                        % Save all raw telegraph values.
                        fields = fieldnames(params);
                        for j = 1:numel(fields)
                            val = params.(fields{j});
                            if isnumeric(val) && isscalar(val)
                                epoch.addParameter([prefix '_' fields{j}], val);
                            elseif ischar(val) && numel(val) < 100
                                epoch.addParameter([prefix '_' fields{j}], val);
                            end
                        end

                        % Save converted values in standard units.
                        epoch.addParameter([prefix '_membraneCapacitance_pF'], params.membraneCapacitance * 1e12);
                        epoch.addParameter([prefix '_seriesResistance_MOhm'], params.seriesResistance / 1e6);
                        epoch.addParameter([prefix '_lpfCutoff_Hz'], params.lpfCutoff);
                    catch
                    end
                end
            catch
            end

         %   controllers = obj.rig.getDevices('Temperature Controller');
        %    if ~isempty(controllers)
         %       epoch.addResponse(controllers{1});
        %    end
            
            % This is for the MEA setup. Check if this is an MEA rig on the
            % first epoch.
            %if ~obj.startedRun
            %    obj.startedRun = true;
            %    obj.isMeaRig = false; % Default
            %    obj.meaFileName = ''; % Default
                
             %   % Check if this is an MEA rig.
             %   mea = obj.rig.getDevices('MEA');
            %    if ~isempty(mea)
            %        obj.isMeaRig = true;
                    
            %        mea = mea{1};
            %        % Try to pull the output file name from the server.
%            %         fname = mea.getFileName(30);
                    
             %       % New tests:
             %       mea.start();
             %       fname = char(mea.fileName);
                    
             %       if ~isempty(fname)
             %           obj.meaFileName = char(fname);
             %       else
             %           obj.meaFileName = '';
             %       end
                    
             %       % Persist the file name
             %       if ~isempty(fname) && ~isempty(obj.persistor)
             %           try
             %               eb = obj.persistor.currentEpochBlock;
             %               if ~isempty(eb)
             %                   eb.setProperty('dataFileName', char(fname))
             %               end
             %           catch
             %           end
            %        end
             %   end
            %end
            
            % Persist the file name to the epoch if it's an MEA rig.
            %if obj.isMeaRig
            %    try
            %        epoch.addParameter('dataFileName', obj.meaFileName);
                    
                    % Create the external trigger to the MEA DAQ.
            %        triggers = obj.rig.getDevices('ExternalTrigger');
            %        if ~isempty(triggers)
            %            epoch.addStimulus(triggers{1}, obj.createTriggerStimulus(triggers{1}));
            %        end
            %    catch ME
            %        disp(ME.message);
            %    end
            %end
        end
        
        function stim = createTriggerStimulus(obj, trigger_device)
            gen = symphonyui.builtin.stimuli.PulseGenerator();
            
            % if strcmp(trigger_device.background.displayUnits,'V') 
            %     amplitude = 5;
            %     units = 'V';
            % else
            %     amplitude = 1;
            %     units = symphonyui.core.Measurement.UNITLESS;
            % end
            
            % % Ensure that pre/stim/tail time are defined.
            % if isprop(obj, 'preTime')
            %     preT = obj.preTime;
            % else
            %     preT = 50;
            % end
            
            % if isprop(obj, 'tailTime')
            %     tailT = obj.tailTime;
            % else
            %     tailT = 50;
            % end
            
            % if isprop(obj, 'stimTime')
            %     stimT = obj.stimTime;
            % else
            %     stimT = 0;
            % end
            % total_time = max(100, preT + stimT + tailT);
            
            % gen.preTime = 0;
            % gen.stimTime = total_time - 1;
            % gen.tailTime = 1;
            % gen.amplitude = amplitude;
            % gen.mean = 0;
            % gen.sampleRate = obj.sampleRate;
            % gen.units = units; %symphonyui.core.Measurement.UNITLESS;
            
            % stim = gen.generate();
        end
        
        function setLedBackground(obj, ledDeviceName, targetMean)
            % SETLEDBACKGROUND  Safely set the LED background with ramp-up.
            %
            %   setLedBackground(obj, ledDeviceName, targetMean)
            %
            % If the LED background is currently 0 and the target is nonzero,
            % this ramps the background up in steps to avoid a sudden onset
            % transient that can saturate photoreceptors or cause artifacts.
            %
            % Call this in prepareRun() instead of directly setting
            % device.background.

            device = obj.rig.getDevice(ledDeviceName);
            units = device.background.displayUnits;
            currentMean = device.background.quantity;

            if targetMean == currentMean
                return;
            end

            % If ramping from 0 (or near 0) to a significant background,
            % step up in increments to allow adaptation.
            if currentMean < 0.01 && targetMean > 0.5
                nSteps = 5;
                stepValues = linspace(currentMean, targetMean, nSteps + 1);
                for i = 2:nSteps  % skip first (current) and last (set below)
                    device.background = symphonyui.core.Measurement(stepValues(i), units);
                    pause(0.2);  % 200 ms per step = ~1 second total ramp
                end
            end

            % Set the final target background.
            device.background = symphonyui.core.Measurement(targetMean, units);
        end

        function ndf = getCurrentNDF(obj)
            % Get the current NDF value from the filter wheel device.
            % Returns 0 if no filter wheel is present.
            ndf = 0;
            try
                devices = obj.rig.getDevices('FilterWheel');
                if ~isempty(devices)
                    ndf = devices{1}.getConfigurationSetting('NDF');
                end
            catch
            end
        end

        function params = readMultiClampParameters(~, device)
            % READMULTICLAMPPARAMETERS  Read amplifier telegraph parameters
            % from a MultiClampDevice via the .NET interop layer.
            %
            %   params = readMultiClampParameters(obj, device)
            %
            % Returns a struct with fields:
            %   operatingMode               'VClamp', 'IClamp', or 'I0'
            %   membraneCapacitance         Whole-cell capacitance (F)
            %   seriesResistance            Series resistance (Ohm)
            %   scaleFactor, scaleFactorUnits
            %   alpha                       Gain
            %   lpfCutoff                   Lowpass filter cutoff (Hz)
            %   externalCommandSensitivity
            %   externalCommandSensitivityUnits
            %
            % MultiClampDevice does NOT use getConfigurationSettingDescriptors().
            % Instead, its telegraph parameters are accessed through
            % CurrentDeviceOutputParameters.Data on the .NET cobj.
            %
            % Note: these parameters are also automatically merged into
            % each epoch's response/stimulus configuration at the .NET
            % level (key: 'MultiClampDeviceConfiguration'), so they ARE
            % saved with recordings even without this explicit read.

            params = struct();

            % Try output parameters first (primary telegraph channel).
            if device.cobj.HasDeviceOutputParameters()
                data = device.cobj.CurrentDeviceOutputParameters.Data;
            elseif device.cobj.HasDeviceInputParameters()
                data = device.cobj.CurrentDeviceInputParameters.Data;
            else
                error('fortenbachlab:noTelegraph', ...
                    'No MultiClamp telegraph parameters available. Is Commander open?');
            end

            params.operatingMode = char(data.OperatingMode.ToString());
            params.membraneCapacitance = double(data.MembraneCapacitance);
            params.seriesResistance = double(data.SeriesResistance);
            params.scaleFactor = double(data.ScaleFactor);
            params.scaleFactorUnits = char(data.ScaleFactorUnits.ToString());
            params.alpha = double(data.Alpha);
            params.lpfCutoff = double(data.LPFCutoff);
            params.externalCommandSensitivity = double(data.ExternalCommandSensitivity);
            params.externalCommandSensitivityUnits = char(data.ExternalCommandSensitivityUnits.ToString());
            params.hardwareType = char(data.HardwareType.ToString());

            % 700B-specific fields.
            try
                params.secondaryAlpha = double(data.SecondaryAlpha);
                params.secondaryLPFCutoff = double(data.SecondaryLPFCutoff);
            catch
            end
        end

        function ensureCalibrationLoaded(obj)
            % Lazy-load the LED calibration so that dependent property
            % getters (evaluated by the property grid before prepareRun)
            % can return real photon-flux values.
            if isempty(obj.ledCalibration)
                try
                    obj.ledCalibration = fortenbachlab.util.LEDCalibration();
                catch
                    % Calibration file not available; leave empty.
                end
            end
        end

        function flux = getPhotonFlux(obj, voltage, ndf)
            % Compute photon flux for a given LED voltage and NDF.
            %   flux = getPhotonFlux(obj, voltage, ndf)
            %   Returns photons/cm2/s, or NaN if calibration unavailable.
            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration)
                flux = NaN;
                return;
            end
            flux = obj.ledCalibration.voltageToFlux(voltage, ndf);
        end

        function str = getPhotonFluxString(obj, voltage, ndf)
            % Return a formatted photon flux string.
            obj.ensureCalibrationLoaded();
            if isempty(obj.ledCalibration)
                str = 'calibration not loaded';
                return;
            end
            str = obj.ledCalibration.fluxString(voltage, ndf);
        end

        function stim = createStimulusFromArray(obj, data, units)
            % CREATESTIMULUSFROMARRAY  Wrap a raw numeric waveform into a
            % Symphony stimulus object suitable for epoch.addStimulus().
            import Symphony.Core.*;
            params = NET.createGeneric('System.Collections.Generic.Dictionary', ...
                {'System.String', 'System.Object'});
            measurements = Measurement.FromArray(data, units);
            rate = Measurement(obj.sampleRate, 'Hz');
            output = OutputData(measurements, rate);
            cobj = RenderedStimulus(class(obj), params, output);
            stim = symphonyui.core.Stimulus(cobj);
        end

        function completeEpoch(obj, epoch)
            completeEpoch@symphonyui.core.Protocol(obj, epoch);
        end

        % ------------------------------------------------------------------
        %  Cell health test pulse helpers
        % ------------------------------------------------------------------

        function mode = detectClampMode(obj, ampName)
            % DETECTCLAMPMODE  Returns 'Vclamp' or 'Iclamp' based on the
            % amplifier background units.
            device = obj.rig.getDevice(ampName);
            units = device.background.displayUnits;
            if strcmp(units, 'mV') || strcmp(units, 'V')
                mode = 'Vclamp';
            else
                mode = 'Iclamp';
            end
        end

        function amp = testPulseAmplitude(obj, ampName)
            % TESTPULSEAMPLITUDE  Return an appropriate test pulse amplitude
            % for the current clamp mode.
            %   Vclamp: 10 mV step  (gives ~20 pA at 500 MOhm Rinput)
            %   Iclamp: -50 pA step
            mode = obj.detectClampMode(ampName);
            if strcmp(mode, 'Vclamp')
                amp = 10;   % mV
            else
                amp = -50;  % pA
            end
        end

        function metrics = computeCellHealthMetrics(obj, epoch, ampName, ~, testPulseStartMs, testPulseDurMs)
            % COMPUTECELLHEALTHMETRICS  Analyse the test pulse region of
            % the response and return Rinput and Ihold/Vhold.
            %
            %   metrics = computeCellHealthMetrics(obj, epoch, ampName, ...
            %       ~, testPulseStartMs, testPulseDurMs)
            %
            %   Returns a struct with fields:
            %     clampMode           'Vclamp' or 'Iclamp'
            %     inputResistance     Rinput in MOhm (steady-state)
            %     holdingCurrent      Ihold in pA  (Vclamp)
            %     holdingVoltage      Vhold in mV  (Iclamp)
            %
            %   Note: With amplifier transient compensation engaged,
            %   Ra and Rm cannot be separated. Rinput reflects the total
            %   input resistance (Ra + Rm).

            metrics = struct();
            mode = obj.detectClampMode(ampName);
            metrics.clampMode = mode;

            responseData = epoch.getResponse(obj.rig.getDevice(ampName));
            [quantities, ~] = responseData.getData();

            sr = obj.sampleRate;

            % Sample indices for the test pulse region.
            baseEnd   = round(testPulseStartMs / 1e3 * sr);
            pulseStart = baseEnd + 1;
            pulsePts   = round(testPulseDurMs / 1e3 * sr);
            pulseEnd   = pulseStart + pulsePts - 1;

            if baseEnd < 2 || pulseEnd > numel(quantities)
                metrics.inputResistance = NaN;
                metrics.holdingCurrent  = NaN;
                metrics.holdingVoltage  = NaN;
                return;
            end

            % Baseline before test pulse.
            baseline = mean(quantities(1:baseEnd));

            if strcmp(mode, 'Vclamp')
                metrics.holdingCurrent = baseline;
                metrics.holdingVoltage = NaN;
            else
                metrics.holdingVoltage = baseline;
                metrics.holdingCurrent = NaN;
            end

            % Steady-state deflection (last 80% of pulse — with
            % amplifier transient compensation the response settles
            % almost immediately).
            ssStart = pulseStart + round(pulsePts * 0.2);
            ssDeflection = mean(quantities(ssStart:pulseEnd)) - baseline;

            % Test pulse amplitude from clamp mode.
            testAmp = obj.testPulseAmplitude(ampName);

            % Compute Rinput = V / I.  mV/pA = GOhm, *1000 = MOhm.
            if strcmp(mode, 'Vclamp')
                if abs(ssDeflection) > 0
                    metrics.inputResistance = abs(testAmp / ssDeflection) * 1000;
                else
                    metrics.inputResistance = NaN;
                end
            else
                % Iclamp: command = pA, response = mV.
                if abs(testAmp) > 0
                    metrics.inputResistance = abs(ssDeflection / testAmp) * 1000;
                else
                    metrics.inputResistance = NaN;
                end
            end
        end

        function data = embedTestPulse(obj, data, ampName)
            % EMBEDTESTPULSE  Overlay a small test pulse at the start of an
            % amp stimulus waveform (during pre-time) for cell health
            % monitoring.
            %
            %   data = embedTestPulse(obj, data, ampName)
            %
            % The test pulse occupies samples 1..testPulseTotalPts:
            %   - 5 ms baseline (unchanged)
            %   - 20 ms test pulse step
            %
            % Total: 25 ms. Fits in any preTime >= 25 ms (min is 50 ms).
            %
            % The step amplitude is auto-detected from clamp mode:
            %   Vclamp: +10 mV above background
            %   Iclamp: -50 pA above background
            sr = obj.sampleRate;
            baselineMs  = 5;
            pulseDurMs  = 20;
            baselinePts = round(baselineMs / 1e3 * sr);
            pulsePts    = round(pulseDurMs / 1e3 * sr);

            if baselinePts + pulsePts > numel(data)
                return;  % not enough room
            end

            device = obj.rig.getDevice(ampName);
            bg = device.background.quantity;
            amp = obj.testPulseAmplitude(ampName);

            % Overlay: leave first baselinePts at whatever they are (bg),
            % set next pulsePts to bg + testPulseAmplitude.
            data(baselinePts+1 : baselinePts+pulsePts) = bg + amp;
        end

        function saveCellHealthMetrics(~, epoch, metrics)
            % SAVECELLHEALTHMETRICS  Write cell health metrics as epoch parameters.
            epoch.addParameter('clampMode', metrics.clampMode);
            epoch.addParameter('inputResistance_MOhm', metrics.inputResistance);
            if strcmp(metrics.clampMode, 'Vclamp')
                epoch.addParameter('holdingCurrent_pA', metrics.holdingCurrent);
            else
                epoch.addParameter('holdingVoltage_mV', metrics.holdingVoltage);
            end
        end

        function tf = cellHealthEnabled(obj)
            % CELLHEALTHENABLED  Returns true if the protocol's pre-time is
            % long enough to embed a test pulse for cell health monitoring.
            % Protocols without a preTime property (e.g. spontaneous
            % recordings that embed the test pulse in the recording itself)
            % always return true.
            if isprop(obj, 'preTime')
                tf = obj.preTime >= obj.MIN_PRETIME_CELL_HEALTH;
            else
                tf = true;
            end
        end

        function warnCellHealthDisabled(obj)
            % WARNCELLHEALTHDISABLED  Print a command-window warning when
            % preTime is too short for cell health metrics.
            warning('fortenbachlab:cellHealth', ...
                ['Cell health metrics DISABLED: preTime (%g ms) is below ' ...
                 'the minimum (%g ms). Increase preTime to enable Rinput tracking.'], ...
                obj.preTime, obj.MIN_PRETIME_CELL_HEALTH);
        end

    end

end

