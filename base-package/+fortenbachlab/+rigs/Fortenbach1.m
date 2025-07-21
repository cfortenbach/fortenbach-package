classdef Fortenbach1 < symphonyui.core.descriptions.RigDescription
    
    methods
        
        function obj = Fortenbach1()
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

%             % Check which analog input channel the temperature controller is on!!
%             temperature = UnitConvertingDevice('Temperature Controller', 'V', 'manufacturer', 'Warner Instruments').bindStream(daq.getStream('ai7'));
%             obj.addDevice(temperature);
            
            % Add the LEDs.
            LED1 = UnitConvertingDevice('LED AO1', 'V').bindStream(daq.getStream('ao1'));
            obj.addDevice(LED1);
            
            % Add the filter wheel.
            filterWheel = edu.washington.riekelab.devices.FilterWheelDevice('comPort', 'COM10');
             
            % Binding the filter wheel to an unused stream only so its configuration settings are written to each epoch.
            % filterWheel.bindStream(daq.getStream('doport1'));
            % daq.getStream('doport1').setBitPosition(filterWheel, 14);
            % obj.addDevice(filterWheel);

            % trigger = UnitConvertingDevice('Oscilloscope Trigger', Measurement.UNITLESS).bindStream(daq.getStream('doport1'));
            % daq.getStream('doport1').setBitPosition(trigger, 0);
            % obj.addDevice(trigger);
             
        end
    end
end

