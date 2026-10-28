classdef Culture < symphonyui.core.persistent.descriptions.SourceDescription

    methods

        function obj = Culture()
            import symphonyui.core.*;

            obj.addProperty('cellType', '', ...
                'description', 'Cell type in culture');
            obj.addProperty('genotype', '', ...
                'description', 'Genetic background of cultured cells');
            obj.addProperty('transfectionStatus', '', ...
                'description', 'Transfection status (e.g. GFP+, untransfected)');

            obj.addAllowableParentType([]);
        end

    end

end
