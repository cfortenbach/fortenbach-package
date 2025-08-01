classdef Demo < symphonyui.core.Protocol
    
    properties
        amp = 'Amp'                     % Output amplifier
        led                             % Output LED
        preTime = 50                    % Pulse leading duration (ms)
        stimTime = 500                  % Pulse duration (ms)
        tailTime = 50                   % Pulse trailing duration (ms)
        pulseAmplitude = 100            % Pulse amplitude (mV)
        numberOfAverages = 5            % Number of epochs
        lightAmplitude = 0.1            % Pulse amplitude (V or norm. [0-1] depending on LED units)
        lightMean = 0                   % Pulse and LED background mean (V or norm. [0-1] depending on LED units)
    end

    methods
    end

end