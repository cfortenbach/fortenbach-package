classdef LEDCalibration
    % LEDCalibration  Utility class for converting LED voltage to photon flux.
    %
    %   This class loads calibration data from a text file and provides
    %   interpolation to convert LED driver voltage (0-10V) to photon flux
    %   (photons/cm2/s) at any NDF setting.
    %
    %   Usage:
    %       cal = fortenbachlab.util.LEDCalibration();
    %       flux = cal.voltageToFlux(5.0, 2.0);  % 5V, NDF 2.0
    %       voltage = cal.fluxToVoltage(1e15, 0); % target 1e15 at NDF 0
    %
    %   The LED driver is assumed to be 100 mA/V (10V = 1000 mA).
    %   NDF attenuation is computed as 10^(-NDF).

    properties (Access = private)
        voltage     % Calibration voltages (column vector)
        fluxNdf0    % Photons/cm2/s at NDF 0 (column vector)
        fitCoeffs   % [slope, intercept] from linear regression (flux = slope*voltage + intercept)
    end

    properties (Constant)
        MA_PER_VOLT = 100;  % LED driver conversion: 100 mA per volt
    end

    methods

        function obj = LEDCalibration()
            % Constructor: loads calibration data and computes linear fit.
            obj = obj.loadCalibration();
            obj.fitCoeffs = polyfit(obj.voltage, obj.fluxNdf0, 1);
        end

        function flux = voltageToFlux(obj, voltage, ndf)
            % VOLTAGETOFLUX  Convert LED voltage to photon flux.
            %
            %   flux = voltageToFlux(obj, voltage, ndf)
            %
            %   Uses a linear best fit of the calibration data.
            %
            %   Inputs:
            %       voltage - LED driver voltage in volts (scalar or vector, 0-10V)
            %       ndf     - ND filter value (0, 0.5, 1.0, 2.0, 3.0, or 4.0)
            %
            %   Output:
            %       flux    - Photon flux in photons/cm2/s

            voltage = max(0, voltage);

            % Linear fit: flux = slope * voltage + intercept.
            fluxBase = max(0, polyval(obj.fitCoeffs, voltage));

            % Apply NDF attenuation.
            flux = fluxBase ./ (10^ndf);
        end

        function voltage = fluxToVoltage(obj, targetFlux, ndf)
            % FLUXTOVOLTAGE  Convert target photon flux to required LED voltage.
            %
            %   voltage = fluxToVoltage(obj, targetFlux, ndf)
            %
            %   Uses the inverse of the linear best fit.
            %
            %   Inputs:
            %       targetFlux - Desired photon flux in photons/cm2/s
            %       ndf        - ND filter value
            %
            %   Output:
            %       voltage    - Required LED voltage (V). Returns NaN if
            %                    the target flux exceeds the maximum achievable.

            % Convert target flux back to NDF 0 equivalent.
            targetFluxNdf0 = targetFlux * (10^ndf);

            % Max flux from the linear fit at 10V.
            maxFlux = polyval(obj.fitCoeffs, max(obj.voltage));
            if targetFluxNdf0 > maxFlux
                voltage = NaN;
                warning('LEDCalibration:exceedsMax', ...
                    'Target flux %.2e exceeds maximum achievable flux %.2e at NDF %.1f', ...
                    targetFlux, maxFlux / (10^ndf), ndf);
                return;
            end

            if targetFluxNdf0 <= 0
                voltage = 0;
                return;
            end

            % Inverse of linear fit: voltage = (flux - intercept) / slope.
            slope = obj.fitCoeffs(1);
            intercept = obj.fitCoeffs(2);
            voltage = (targetFluxNdf0 - intercept) / slope;
            voltage = max(0, voltage);
        end

        function str = fluxString(obj, voltage, ndf)
            % FLUXSTRING  Return a formatted string of the photon flux.
            %
            %   str = fluxString(obj, voltage, ndf)
            %
            %   Returns a string like "2.55e+16 photons/cm2/s"

            flux = obj.voltageToFlux(voltage, ndf);
            if flux == 0
                str = '0 photons/cm2/s';
            else
                exponent = floor(log10(abs(flux)));
                mantissa = flux / 10^exponent;
                str = sprintf('%.2fe+%02d photons/cm2/s', mantissa, exponent);
            end
        end

        function mA = voltageToMilliamps(~, voltage)
            % VOLTAGETOMILLIAMPS  Convert DAQ voltage to LED current.
            mA = voltage * 100;  % 100 mA/V
        end

    end

    methods (Access = private)

        function obj = loadCalibration(obj)
            % Load calibration data from text file via Package resource loader.
            calibFile = '';

            try
                calibFile = fortenbachlab.Package.getCalibrationResource( ...
                    'rigs', 'fortenbach', 'led_455nm_calibration.txt');
                if ~exist(calibFile, 'file')
                    calibFile = '';
                end
            catch
                calibFile = '';
            end

            if isempty(calibFile)
                warning('LEDCalibration:noFile', 'Calibration file not found. Using hardcoded defaults.');
                obj.voltage  = [0; 0.1; 0.5; 1.0; 3.0; 5.0; 8.0; 10.0];
                obj.fluxNdf0 = [0; 9.05e14; 4.68e15; 9.18e15; 2.55e16; 4.01e16; 5.99e16; 7.23e16];
                return;
            end

            % Parse the text file (skip lines starting with %).
            fid = fopen(calibFile, 'r');
            voltages = [];
            fluxes = [];
            while ~feof(fid)
                line = fgetl(fid);
                if isempty(line) || line(1) == '%'
                    continue;
                end
                vals = sscanf(line, '%f\t%f');
                if numel(vals) == 2
                    voltages(end+1) = vals(1); %#ok<AGROW>
                    fluxes(end+1) = vals(2);   %#ok<AGROW>
                end
            end
            fclose(fid);

            obj.voltage = voltages(:);
            obj.fluxNdf0 = fluxes(:);
        end

    end

end
