classdef Cell < symphonyui.core.persistent.descriptions.SourceDescription

    methods

        function obj = Cell()
            import symphonyui.core.*;

            obj.addProperty('targetType', '', ...
                'description', 'The target cell type under investigation');
            obj.addProperty('confirmedType', '', ...
                'description', 'The confirmed type of the recorded cell');
            obj.addProperty('recordingLocation', '', ...
                'description', 'The recording location in the cell (e.g. axonal, dendritic, somatic)');

            obj.addAllowableParentType('fortenbachlab.sources.Preparation');
        end

    end

end
