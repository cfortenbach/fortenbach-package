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
            
            % Add the filter wheel (Thorlabs FW102C on COM10).
            % NDF values: [0, 0.5, 1.0, 2.0, 3.0, 4.0] in positions 1-6.
            filterWheel = edu.washington.riekelab.devices.FilterWheelDevice('comPort', 'COM10', 'NDF', 0.0);

            % Filter wheel is controlled via serial COM port, not DAQ digital I/O.
            obj.addDevice(filterWheel);
             
        end
    end
end

