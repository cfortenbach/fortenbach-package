classdef Fortenbach1Amp < symphonyui.core.descriptions.RigDescription
    
    methods
        
        function obj = Fortenbach1Amp()
            import symphonyui.builtin.daqs.*;
            import symphonyui.builtin.devices.*;
            import symphonyui.core.*;
            import edu.washington.*;

            % Add the NiDAQ A/D board.
            daq = NiDaqController();
            obj.daqController = daq;
            
            % Add the Multiclamp device (demo mode).
            amp1 = MultiClampDevice('Amp1', 1).bindStream(daq.getStream('ao0')).bindStream(daq.getStream('ai0'));
            obj.addDevice(amp1);

            % Check which analog input channel the temperature controller is on!!
%             temperature = UnitConvertingDevice('Temperature Controller', 'V', 'manufacturer', 'Warner Instruments').bindStream(daq.getStream('ai7'));
%             obj.addDevice(temperature);
            
            % Add the LEDs.
            uvRamp = importdata(riekelab.Package.getCalibrationResource('rigs', 'mea', 'uv_led_gamma_ramp.txt'));
            uv = CalibratedDevice('LED', Measurement.NORMALIZED, uvRamp(:, 1), uvRamp(:, 2)).bindStream(daq.getStream('ao1'));
            uv.addConfigurationSetting('ndfs', {}, ...
                'type', PropertyType('cellstr', 'row', {'C1', 'C2', 'C3', 'C4', 'C5'}));
            uv.addResource('ndfAttenuations', containers.Map( ...
                {'C1', 'C2', 'C3', 'C4', 'C5'}, ...
                {0.2768, 0.5076, 0.9281, 2.1275, 2.5022}));
            uv.addResource('fluxFactorPaths', containers.Map( ...
                {'none'}, {riekelab.Package.getCalibrationResource('rigs', 'mea', 'uv_led_flux_factors.txt')}));
            uv.addConfigurationSetting('lightPath', '', ...
                'type', PropertyType('char', 'row', {'', 'below', 'above'}));
            uv.addResource('spectrum', importdata(riekelab.Package.getCalibrationResource('rigs', 'mea', 'uv_led_spectrum.txt')));          
            obj.addDevice(uv);
            
            trigger = UnitConvertingDevice('Oscilloscope Trigger', Measurement.UNITLESS).bindStream(daq.getStream('doport0'));
            daq.getStream('doport0').setBitPosition(trigger, 0);
            obj.addDevice(trigger);

%             % Add the filter wheel.
%             filterWheel = edu.washington.riekelab.devices.FilterWheelDevice('comPort', 'COM5');
%             
%             % Binding the filter wheel to an unused stream only so its configuration settings are written to each epoch.
%             filterWheel.bindStream(daq.getStream('doport1'));
%             daq.getStream('doport1').setBitPosition(filterWheel, 14);
%             obj.addDevice(filterWheel);
%             
        end
    end
end

