classdef HoldingPotentialModule < symphonyui.ui.Module
    % Holding Potential Module with quick-set amp presets.
    %
    %   Extends the standard BackgroundControl module with preset buttons
    %   for common holding potentials (-60 mV, -40 mV) and a custom entry
    %   field.  All output devices are shown in a table; the presets apply
    %   to the first device whose name contains 'Amp'.

    properties (Access = private)
        devices
        deviceListeners
        deviceTable         % uitable for editing background values

        % Amp preset controls
        presetPanel
        preset60Btn
        preset40Btn
        preset0Btn
        customField
        customSetBtn
        ampStatusLabel
    end

    methods

        function createUi(obj, figureHandle)
            figureHandle.Name = 'Holding Potential Module';
            figureHandle.Position(3:4) = [360 290];

            mainGrid = uigridlayout(figureHandle, [2 1], ...
                'RowHeight', {'1x', 'fit'}, 'Padding', [6 6 6 6], ...
                'RowSpacing', 8);

            % --- Device table (top) ---
            obj.deviceTable = uitable(mainGrid, ...
                'ColumnName', {'Device', 'Background', 'Units'}, ...
                'ColumnEditable', [false true false], ...
                'ColumnWidth', {'1x', 80, 60}, ...
                'CellEditCallback', @(src, evt)obj.onCellEdit(src, evt));
            obj.deviceTable.Layout.Row = 1;

            % --- Amp presets panel (bottom) ---
            obj.presetPanel = uipanel(mainGrid, 'Title', 'Amp Holding Potential');
            obj.presetPanel.Layout.Row = 2;

            pg = uigridlayout(obj.presetPanel, [2 5], ...
                'RowHeight', {30, 30}, ...
                'ColumnWidth', {'fit', 'fit', 'fit', '1x', 'fit'}, ...
                'Padding', [8 4 8 4], 'ColumnSpacing', 6, 'RowSpacing', 6);

            % Row 1: preset buttons
            obj.preset60Btn = uibutton(pg, 'Text', '-60 mV', ...
                'ButtonPushedFcn', @(~,~)obj.applyAmpPreset(-60));
            obj.preset60Btn.Layout.Row = 1;
            obj.preset60Btn.Layout.Column = 1;

            obj.preset40Btn = uibutton(pg, 'Text', '-40 mV', ...
                'ButtonPushedFcn', @(~,~)obj.applyAmpPreset(-40));
            obj.preset40Btn.Layout.Row = 1;
            obj.preset40Btn.Layout.Column = 2;

            obj.preset0Btn = uibutton(pg, 'Text', '0 mV', ...
                'ButtonPushedFcn', @(~,~)obj.applyAmpPreset(0));
            obj.preset0Btn.Layout.Row = 1;
            obj.preset0Btn.Layout.Column = 3;

            obj.ampStatusLabel = uilabel(pg, 'Text', '', ...
                'HorizontalAlignment', 'right', ...
                'FontColor', [0.3 0.3 0.3]);
            obj.ampStatusLabel.Layout.Row = 1;
            obj.ampStatusLabel.Layout.Column = [4 5];

            % Row 2: custom value entry
            customLbl = uilabel(pg, 'Text', 'Custom (mV):');
            customLbl.Layout.Row = 2;
            customLbl.Layout.Column = 1;

            obj.customField = uieditfield(pg, 'numeric', 'Value', 0);
            obj.customField.Layout.Row = 2;
            obj.customField.Layout.Column = [2 4];

            obj.customSetBtn = uibutton(pg, 'Text', 'Set', ...
                'ButtonPushedFcn', @(~,~)obj.applyAmpPreset(obj.customField.Value));
            obj.customSetBtn.Layout.Row = 2;
            obj.customSetBtn.Layout.Column = 5;
        end

    end

    methods (Access = protected)

        function willGo(obj)
            obj.devices = obj.configurationService.getOutputDevices();
            obj.populateTable();
            obj.updateAmpStatus();
        end

        function bind(obj)
            bind@symphonyui.ui.Module(obj);
            obj.bindDevices();

            c = obj.configurationService;
            obj.addListener(c, 'InitializedRig', @obj.onServiceInitializedRig);
        end

    end

    methods (Access = private)

        function bindDevices(obj)
            obj.deviceListeners = {};
            for i = 1:numel(obj.devices)
                obj.deviceListeners{end + 1} = obj.addListener( ...
                    obj.devices{i}, 'background', 'PostSet', @obj.onDeviceSetBackground);
            end
        end

        function unbindDevices(obj)
            while ~isempty(obj.deviceListeners)
                obj.removeListener(obj.deviceListeners{1});
                obj.deviceListeners(1) = [];
            end
        end

        function populateTable(obj)
            n = numel(obj.devices);
            if n == 0
                obj.deviceTable.Data = {};
                return;
            end
            data = cell(n, 3);
            for i = 1:n
                d = obj.devices{i};
                data{i, 1} = d.name;
                data{i, 2} = d.background.quantity;
                data{i, 3} = d.background.displayUnits;
            end
            obj.deviceTable.Data = data;
        end

        function onCellEdit(obj, ~, evt)
            row = evt.Indices(1);
            col = evt.Indices(2);
            if col ~= 2
                return;
            end
            newVal = evt.NewData;
            if ischar(newVal) || isstring(newVal)
                newVal = str2double(newVal);
            end
            if isnan(newVal)
                obj.populateTable();
                return;
            end

            device = obj.devices{row};
            oldBackground = device.background;
            device.background = symphonyui.core.Measurement(newVal, device.background.displayUnits);
            try
                device.applyBackground();
            catch x
                device.background = oldBackground;
                obj.populateTable();
                uialert(obj.getFigureHandle(), x.message, 'Background Error');
                return;
            end

            % Update background for all modes if the device supports modes
            if ismethod(device, 'availableModes')
                for i = 1:numel(device.availableModes)
                    mode = device.availableModes{i};
                    b = device.getBackgroundForMode(mode);
                    device.setBackgroundForMode(mode, ...
                        symphonyui.core.Measurement(newVal, b.displayUnits));
                end
            end

            obj.updateAmpStatus();
        end

        % --- Amp preset logic ---

        function dev = findAmpDevice(obj)
            % Find the first output device whose name contains 'Amp'.
            dev = [];
            for i = 1:numel(obj.devices)
                if contains(obj.devices{i}.name, 'Amp', 'IgnoreCase', true)
                    dev = obj.devices{i};
                    return;
                end
            end
        end

        function applyAmpPreset(obj, mV)
            dev = obj.findAmpDevice();
            if isempty(dev)
                uialert(obj.getFigureHandle(), ...
                    'No amplifier device found.', 'Preset Error');
                return;
            end

            oldBackground = dev.background;
            dev.background = symphonyui.core.Measurement(mV, dev.background.displayUnits);
            try
                dev.applyBackground();
            catch x
                dev.background = oldBackground;
                obj.populateTable();
                uialert(obj.getFigureHandle(), x.message, 'Preset Error');
                return;
            end

            % Update background for all modes
            if ismethod(dev, 'availableModes')
                for i = 1:numel(dev.availableModes)
                    mode = dev.availableModes{i};
                    b = dev.getBackgroundForMode(mode);
                    dev.setBackgroundForMode(mode, ...
                        symphonyui.core.Measurement(mV, b.displayUnits));
                end
            end

            obj.populateTable();
            obj.updateAmpStatus();
        end

        function updateAmpStatus(obj)
            dev = obj.findAmpDevice();
            if isempty(dev)
                obj.ampStatusLabel.Text = '(no amp found)';
                return;
            end
            val = dev.background.quantity;
            units = dev.background.displayUnits;
            obj.ampStatusLabel.Text = sprintf('%s: %g %s', dev.name, val, units);
        end

        % --- Event handlers ---

        function onServiceInitializedRig(obj, ~, ~)
            obj.unbindDevices();
            obj.devices = obj.configurationService.getOutputDevices();
            obj.populateTable();
            obj.updateAmpStatus();
            obj.bindDevices();
        end

        function onDeviceSetBackground(obj, ~, ~)
            obj.populateTable();
            obj.updateAmpStatus();
        end

    end

end
