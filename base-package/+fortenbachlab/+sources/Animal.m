classdef Animal < symphonyui.core.persistent.descriptions.SourceDescription

    methods

        function obj = Animal()
            import symphonyui.core.*;

            obj.addProperty('id', '', ...
                'description', 'ID of animal (lab convention)');
            obj.addProperty('description', '', ...
                'description', 'Description of subject and where subject came from (e.g. breeder)');
            obj.addProperty('species', '', ...
                'description', 'Species');
            obj.addProperty('genotype', '', ...
                'description', 'Genetic strain');
            obj.addProperty('sex', '', ...
                'type', PropertyType('char', 'row', {'', 'male', 'female'}));
            obj.addProperty('age', '', ...
                'description', 'Age of animal');
            obj.addProperty('weight', '', ...
                'description', 'Weight at time of experiment');

            obj.addAllowableParentType([]);
        end

    end

end
