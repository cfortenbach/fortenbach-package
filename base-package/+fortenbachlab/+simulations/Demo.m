classdef Demo < symphonyui.core.Simulation

    methods

        function inputMap = run(obj, daq, outputMap, timeStep)
            inputMap = containers.Map();

            inputStreams = daq.getInputStreams();
            for i = 1:numel(inputStreams)
                inStream = inputStreams{i};

                if ~inStream.active
                    % We don't care to process inactive input streams (i.e. channels without devices).
                    continue;
                end

                % Simulate input data.
                rate = inStream.sampleRate;
                nsamples = seconds(timeStep) * rate.quantityInBaseUnits;
                if strcmp(inStream.name, 'ai0')
                    % Simulate the output signal + noise.
                    outData = outputMap('ao0');
                    [outQuantities, outUnits] = outData.getData();
                    quantities = outQuantities + rand(1, nsamples) - 0.5;
                elseif strncmp(inStream.name, 'diport', 6)
                    % Simulate digital noise.
                    quantities = randi(2^16-1, 1, nsamples);
                else
                    % Simulate analog noise.
                    quantities = rand(1, nsamples) - 0.5;
                end

                units = inStream.measurementConversionTarget;

                inputMap(inStream.name) = symphonyui.core.InputData(quantities, units, rate);
            end
        end

    end

end