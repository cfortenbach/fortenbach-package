classdef Demo < symphonyui.core.descriptions.RigDescription

    methods

        function obj = Demo()
            import symphonyui.builtin.daqs.*;
            import symphonyui.builtin.devices.*;
            import fortenbachlab.*;
            import symphonyui.core.*;
            import edu.washington.*;

            daq = NiSimulationDaqController();
            daq.simulation = simulations.Demo();
            obj.daqController = daq;

            % Add a MultiClamp 700B device with name = Amp, channel = 1
            amp = MultiClampDevice('Amp', 1).bindStream(daq.getStream('ao0')).bindStream(daq.getStream('ai0'));
            obj.addDevice(amp);

            % Add the LEDs.
            LED1 = UnitConvertingDevice('LED AO1', 'V').bindStream(daq.getStream('ao1'));
            obj.addDevice(LED1);
        end

    end

end