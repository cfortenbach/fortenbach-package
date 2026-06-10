classdef FilterWheelDevice < symphonyui.core.Device

    properties (Access = private)
        wheelPosition
        ndf
    end


    properties (Access = private)
        filterWheel
        ndfValues = [0 0.5 1.0 2.0 3.0 4.0];
        isOpen
        comPort
    end

    methods
        function obj = FilterWheelDevice(varargin)

            ip = inputParser();
            ip.addParameter('comPort', 'COM13', @ischar);
            ip.addParameter('NDF', 4.0, @isnumeric);
            ip.parse(varargin{:});

            cobj = Symphony.Core.UnitConvertingExternalDevice('FilterWheel', 'ThorLabs', Symphony.Core.Measurement(0, symphonyui.core.Measurement.UNITLESS));
            obj@symphonyui.core.Device(cobj);
            obj.cobj.MeasurementConversionTarget = symphonyui.core.Measurement.UNITLESS;

            obj.addConfigurationSetting('NDF', 4.0);
            obj.comPort = ip.Results.comPort;

            % Try to connect.
            obj.connect(obj.comPort);

            if obj.isOpen
                obj.setNDF(ip.Results.NDF);
                obj.ndf = 4;
            end
        end

        function connect(obj, comPort)
            obj.isOpen = false;
            obj.comPort = comPort;
            try
                % Clean up any stale serialport objects bound to this port.
                try
                    stale = serialportfind('Port', comPort);
                    if ~isempty(stale)
                        delete(stale);
                    end
                catch
                end

                obj.filterWheel = serialport(comPort, 115200, ...
                    'DataBits', 8, 'StopBits', 1);
                configureTerminator(obj.filterWheel, 'CR');
                obj.isOpen = true;
            catch e
                obj.isOpen = false;
                warning('FilterWheelDevice:ConnectFailed', ...
                    'Failed to open %s: %s', comPort, e.message);
            end
        end

        function close(obj)
            if obj.isOpen
                try delete(obj.filterWheel); catch, end
                obj.filterWheel = [];
                obj.isOpen = false;
            end
        end

        function tf = tryReconnect(obj)
            % Attempt to reopen the serial connection to the filter wheel.
            if isempty(obj.comPort)
                tf = false;
                return;
            end
            try delete(obj.filterWheel); catch, end
            obj.filterWheel = [];
            obj.connect(obj.comPort);
            tf = obj.isOpen;
        end

        function moveWheel(obj, position)
            if ~obj.isOpen
                if ~obj.tryReconnect()
                    error('FilterWheelDevice:NotConnected', ...
                        'Filter wheel serial port is not open. Check that COM port is available.');
                end
            end
            try
                writeline(obj.filterWheel, ['pos=' num2str(position)]);
            catch e
                % Port may have gone stale; try reconnect once.
                if obj.tryReconnect()
                    writeline(obj.filterWheel, ['pos=' num2str(position)]);
                else
                    rethrow(e);
                end
            end
            obj.wheelPosition = position;
        end

        function setNDF(obj, nd)
            try
                obj.moveWheel(find(obj.ndfValues == nd, 1));
                obj.setReadOnlyConfigurationSetting('NDF', nd);
            catch e
                disp(e.message);
            end
        end

        function nd = getNDF(obj)
            nd = obj.getConfigurationSetting('NDF');
        end


        function position = getCurrentPosition(obj)
            position = '';
            if ~obj.isOpen
                if ~obj.tryReconnect()
                    return;
                end
            end
            try
                writeline(obj.filterWheel, 'pos=?');
                position = readline(obj.filterWheel);
            catch
                position = '';
            end
        end

        function tf = getIsOpen(obj)
            tf = obj.isOpen;
        end
    end
end
