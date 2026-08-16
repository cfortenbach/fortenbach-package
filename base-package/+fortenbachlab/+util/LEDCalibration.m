classdef LEDCalibration
    % LEDCalibration  Utility class for converting LED voltage to photon flux.
    %
    %   This class loads calibration data from a text file and provides
    %   interpolation to convert LED driver voltage (0-10V) to photon flux
    %   (photons/cm2/s) at any NDF setting. Supports multiple objectives
    %   (4x, 10x, 60x) with per-objective calibration curves.
    %
    %   New-format calibration files contain raw optical power measurements
    %   organized by objective. Power is converted to photon flux using the
    %   known LED wavelength (455 nm) and spot diameter for each objective.
    %   Legacy files with pre-computed flux values are also supported.
    %
    %   Usage:
    %       cal = fortenbachlab.util.LEDCalibration();
    %       flux = cal.voltageToFlux(5.0, 2.0, '4x');
    %       voltage = cal.fluxToVoltage(1e15, 0, '10x');
    %       objs = cal.getAvailableObjectives();
    %
    %   The LED driver is assumed to be 100 mA/V (10V = 1000 mA).
    %   NDF attenuation is computed as 10^(-NDF).

    properties (Access = private)
        calibData       % containers.Map keyed by objective ('4x','10x','60x')
                        % Each value is a struct with fields:
                        %   voltage         - calibration voltages (column vector)
                        %   fluxNdf0        - photon flux at NDF 0 (column vector)
                        %   fitCoeffs       - [slope, intercept] from polyfit
                        %   spotDiameter_mm - spot diameter in mm
        calibFilePath   % Path to the calibration file used
    end

    properties (Constant)
        MA_PER_VOLT = 100;  % LED driver conversion: 100 mA per volt
    end

    properties (Constant, Access = private)
        WAVELENGTH_NM = 455;
        % E_photon = h * c / lambda
        E_PHOTON = (6.62607e-34 * 2.99792e8) / (455e-9);  % ~4.3663e-19 J
    end

    methods

        function obj = LEDCalibration()
            % Constructor: finds the most recent calibration file, parses
            % all objectives, converts power to photon flux, and computes
            % linear fits for interpolation.
            obj.calibData = containers.Map();
            obj.calibFilePath = fortenbachlab.util.LEDCalibration.findCalibrationFile();

            if isempty(obj.calibFilePath)
                fprintf('LEDCalibration: No calibration file found. Using hardcoded defaults.\n');
                obj = obj.loadDefaults();
            else
                fprintf('LEDCalibration: Loading from %s\n', obj.calibFilePath);
                obj = obj.loadFromFile(obj.calibFilePath);
            end
            fprintf('LEDCalibration: Available objectives: %s\n', ...
                strjoin(obj.calibData.keys(), ', '));
        end

        function flux = voltageToFlux(obj, voltage, ndf, objective)
            % VOLTAGETOFLUX  Convert LED voltage to photon flux.
            %
            %   flux = voltageToFlux(obj, voltage, ndf, objective)
            %
            %   Uses a linear best fit of the calibration data.
            %
            %   Inputs:
            %       voltage   - LED driver voltage (scalar or vector, 0-10V)
            %       ndf       - ND filter value (0, 0.5, 1.0, 2.0, 3.0, 4.0)
            %       objective - Objective string: '4x', '10x', or '60x'
            %
            %   Output:
            %       flux      - Photon flux in photons/cm2/s

            objective = obj.resolveObjective(objective);
            data = obj.calibData(objective);

            voltage = max(0, voltage);

            % Linear fit: flux = slope * voltage + intercept.
            fluxBase = max(0, polyval(data.fitCoeffs, voltage));

            % Apply NDF attenuation.
            flux = fluxBase ./ (10^ndf);
        end

        function voltage = fluxToVoltage(obj, targetFlux, ndf, objective)
            % FLUXTOVOLTAGE  Convert target photon flux to required LED voltage.
            %
            %   voltage = fluxToVoltage(obj, targetFlux, ndf, objective)
            %
            %   Uses the inverse of the linear best fit.
            %
            %   Inputs:
            %       targetFlux - Desired photon flux in photons/cm2/s
            %       ndf        - ND filter value
            %       objective  - Objective string: '4x', '10x', or '60x'
            %
            %   Output:
            %       voltage    - Required LED voltage (V). Returns NaN if
            %                    the target flux exceeds the maximum achievable.

            objective = obj.resolveObjective(objective);
            data = obj.calibData(objective);

            % Convert target flux back to NDF 0 equivalent.
            targetFluxNdf0 = targetFlux * (10^ndf);

            % Max flux from the linear fit at the highest calibration voltage.
            maxFlux = polyval(data.fitCoeffs, max(data.voltage));
            if targetFluxNdf0 > maxFlux
                voltage = NaN;
                warning('LEDCalibration:exceedsMax', ...
                    'Target flux %.2e exceeds maximum achievable flux %.2e at NDF %.1f for %s', ...
                    targetFlux, maxFlux / (10^ndf), ndf, objective);
                return;
            end

            if targetFluxNdf0 <= 0
                voltage = 0;
                return;
            end

            % Inverse of linear fit: voltage = (flux - intercept) / slope.
            slope = data.fitCoeffs(1);
            intercept = data.fitCoeffs(2);
            voltage = (targetFluxNdf0 - intercept) / slope;
            voltage = max(0, voltage);
        end

        function str = fluxString(obj, voltage, ndf, objective)
            % FLUXSTRING  Return a formatted string of the photon flux.
            %
            %   str = fluxString(obj, voltage, ndf, objective)
            %
            %   Returns a string like "2.55e+16 photons/cm2/s"

            flux = obj.voltageToFlux(voltage, ndf, objective);
            if flux == 0
                str = '0 photons/cm2/s';
            else
                exponent = floor(log10(abs(flux)));
                mantissa = flux / 10^exponent;
                str = sprintf('%.2fe+%02d photons/cm2/s', mantissa, exponent);
            end
        end

        function f = getCalibrationFile(obj)
            % GETCALIBRATIONFILE  Return the path to the calibration file.
            f = obj.calibFilePath;
        end

        function d = getSpotDiameter(obj, objective)
            % GETSPOTDIAMETER  Return spot diameter in mm for an objective.
            objective = obj.resolveObjective(objective);
            data = obj.calibData(objective);
            d = data.spotDiameter_mm;
        end

        function objectives = getAvailableObjectives(obj)
            % GETAVAILABLEOBJECTIVES  Return cell array of available objectives.
            objectives = obj.calibData.keys();
        end

    end

    methods (Access = private)

        function objective = resolveObjective(obj, objective)
            % Normalize objective string and validate it exists in calibData.
            objective = lower(strtrim(objective));
            if ~obj.calibData.isKey(objective)
                error('LEDCalibration:unknownObjective', ...
                    'Objective ''%s'' not found. Available: %s', ...
                    objective, strjoin(obj.calibData.keys(), ', '));
            end
        end

        function obj = loadDefaults(obj)
            % Load hardcoded default calibration data for all objectives.
            % Values derived from led_455nm_calibration_260812.txt.
            E_ph = fortenbachlab.util.LEDCalibration.E_PHOTON;

            % --- 4x (spot 5.5 mm) ---
            A4 = pi * (5.5/20)^2;
            pwr4 = [0.18e-9; 77.7e-6; 0.406e-3; 0.797e-3; 2.22e-3; 3.51e-3; 5.26e-3; 6.34e-3];
            s4 = struct();
            s4.voltage         = [0; 0.1; 0.5; 1.0; 3.0; 5.0; 8.0; 10.0];
            s4.fluxNdf0        = pwr4 ./ (E_ph * A4);
            s4.fitCoeffs       = polyfit(s4.voltage, s4.fluxNdf0, 1);
            s4.spotDiameter_mm = 5.5;
            obj.calibData('4x') = s4;

            % --- 10x (spot 2.2 mm) ---
            A10 = pi * (2.2/20)^2;
            pwr10 = [0.056e-9; 44.77e-6; 0.236e-3; 0.464e-3; 1.297e-3; 2.045e-3; 3.068e-3; 3.703e-3];
            s10 = struct();
            s10.voltage         = [0; 0.1; 0.5; 1.0; 3.0; 5.0; 8.0; 10.0];
            s10.fluxNdf0        = pwr10 ./ (E_ph * A10);
            s10.fitCoeffs       = polyfit(s10.voltage, s10.fluxNdf0, 1);
            s10.spotDiameter_mm = 2.2;
            obj.calibData('10x') = s10;

            % --- 60x (spot 0.405 mm) ---
            A60 = pi * (0.405/20)^2;
            pwr60 = [0.80e-9; 7.07e-6; 37.1e-6; 72.9e-6; 0.20e-3; 0.321e-3; 0.481e-3; 0.581e-3];
            s60 = struct();
            s60.voltage         = [0; 0.1; 0.5; 1.0; 3.0; 5.0; 8.0; 10.0];
            s60.fluxNdf0        = pwr60 ./ (E_ph * A60);
            s60.fitCoeffs       = polyfit(s60.voltage, s60.fluxNdf0, 1);
            s60.spotDiameter_mm = 0.405;
            obj.calibData('60x') = s60;
        end

        function obj = loadFromFile(obj, filePath)
            % Read and parse a calibration file (new or legacy format).
            fid = fopen(filePath, 'r');
            if fid == -1
                warning('LEDCalibration:cantOpen', ...
                    'Cannot open calibration file: %s', filePath);
                obj = obj.loadDefaults();
                return;
            end

            lines = {};
            while ~feof(fid)
                ln = fgetl(fid);
                if ischar(ln)
                    lines{end+1} = ln; %#ok<AGROW>
                end
            end
            fclose(fid);

            % Parse spot diameters from header comments.
            spotDiameters = fortenbachlab.util.LEDCalibration.parseSpotDiameters(lines);

            % Detect format: new files have section headers with objective
            % identifiers; legacy files have only voltage<TAB>flux data.
            hasHeaders = false;
            for i = 1:numel(lines)
                trimmed = strtrim(lines{i});
                if isempty(trimmed) || trimmed(1) == '%'
                    continue;
                end
                if fortenbachlab.util.LEDCalibration.isSectionHeader(trimmed)
                    hasHeaders = true;
                    break;
                end
            end

            if hasHeaders
                obj = obj.parseMultiObjective(lines, spotDiameters);
            else
                obj = obj.parseLegacy(lines, spotDiameters);
            end
        end

        function obj = parseLegacy(obj, lines, spotDiameters)
            % Parse old-format file: voltage<TAB>flux (already photons/cm2/s).
            % Treated as a single '4x' objective with no power conversion.
            voltages = [];
            fluxes = [];
            for i = 1:numel(lines)
                trimmed = strtrim(lines{i});
                if isempty(trimmed) || trimmed(1) == '%'
                    continue;
                end
                vals = sscanf(trimmed, '%f\t%f');
                if numel(vals) == 2
                    voltages(end+1) = vals(1); %#ok<AGROW>
                    fluxes(end+1)   = vals(2); %#ok<AGROW>
                end
            end

            if isfield(spotDiameters, 'x4')
                spotD = spotDiameters.x4;
            else
                spotD = 5.5;
            end

            s = struct();
            s.voltage         = voltages(:);
            s.fluxNdf0        = fluxes(:);
            s.fitCoeffs       = polyfit(s.voltage, s.fluxNdf0, 1);
            s.spotDiameter_mm = spotD;
            obj.calibData('4x') = s;
        end

        function obj = parseMultiObjective(obj, lines, spotDiameters)
            % Parse new-format file with per-objective power measurements.
            % Each section starts with a header line containing the objective
            % identifier and is followed by voltage<TAB>power data lines.
            currentObj = '';
            voltages   = [];
            powers_W   = [];

            for i = 1:numel(lines)
                trimmed = strtrim(lines{i});

                % Skip comments.
                if ~isempty(trimmed) && trimmed(1) == '%'
                    continue;
                end

                % Check for section header.
                if ~isempty(trimmed) && fortenbachlab.util.LEDCalibration.isSectionHeader(trimmed)
                    % Store the previous section before starting a new one.
                    if ~isempty(currentObj) && ~isempty(voltages)
                        obj = obj.storeSection(currentObj, voltages, ...
                            powers_W, spotDiameters);
                    end
                    currentObj = fortenbachlab.util.LEDCalibration.extractObjective(trimmed);
                    voltages   = [];
                    powers_W   = [];
                    continue;
                end

                % Skip blank lines.
                if isempty(trimmed)
                    continue;
                end

                % Parse data line within the current section.
                if ~isempty(currentObj)
                    [v, p] = fortenbachlab.util.LEDCalibration.parseDataLine(trimmed);
                    if ~isnan(v) && ~isnan(p)
                        voltages(end+1) = v; %#ok<AGROW>
                        powers_W(end+1) = p; %#ok<AGROW>
                    end
                end
            end

            % Store the final section.
            if ~isempty(currentObj) && ~isempty(voltages)
                obj = obj.storeSection(currentObj, voltages, ...
                    powers_W, spotDiameters);
            end

            if obj.calibData.Count == 0
                warning('LEDCalibration:noData', ...
                    'No calibration data parsed from file.');
                obj = obj.loadDefaults();
            end
        end

        function obj = storeSection(obj, objective, voltages, powers_W, spotDiameters)
            % Convert raw optical power to photon flux and store in calibData.
            %
            %   flux = P / (E_photon * A)
            %   A    = pi * (d_mm / 20)^2   [cm^2]

            % Map objective string to struct field name ('4x' -> 'x4').
            fieldName = ['x' objective(1:end-1)];

            % Look up spot diameter: parsed from file header, then defaults.
            defaultSpots = struct('x4', 5.5, 'x10', 2.2, 'x60', 0.405);
            if ~isempty(fieldnames(spotDiameters)) && isfield(spotDiameters, fieldName)
                spotD = spotDiameters.(fieldName);
            elseif isfield(defaultSpots, fieldName)
                spotD = defaultSpots.(fieldName);
            else
                warning('LEDCalibration:unknownSpot', ...
                    'No spot diameter for objective %s. Using 4x default.', objective);
                spotD = 5.5;
            end

            % Illumination area: diameter (mm) -> radius (cm) -> area (cm^2).
            A_cm2 = pi * (spotD / 20)^2;

            % Photon flux = P_watts / (E_photon * A_cm2).
            fluxValues = powers_W ./ (fortenbachlab.util.LEDCalibration.E_PHOTON * A_cm2);

            s = struct();
            s.voltage         = voltages(:);
            s.fluxNdf0        = fluxValues(:);
            s.fitCoeffs       = polyfit(s.voltage, s.fluxNdf0, 1);
            s.spotDiameter_mm = spotD;
            obj.calibData(objective) = s;
        end

    end

    methods (Static, Access = private)

        function filePath = findCalibrationFile()
            % Find the most recent LED calibration file by sorting filenames.
            % Checks Z:\Scientifica Calibration Data first, then falls back
            % to the package calibration-resources directory.
            filePath = '';

            % Check the shared network drive.
            networkDir = 'Z:\Scientifica Calibration Data';
            if isfolder(networkDir)
                listing = dir(fullfile(networkDir, 'led_455nm_calibration_*.txt'));
                if ~isempty(listing)
                    names = sort({listing.name});
                    filePath = fullfile(networkDir, names{end});
                    return;
                end
            end

            % Fall back to the package resource directory.
            try
                resourceDir = fortenbachlab.Package.getCalibrationResource( ...
                    'rigs', 'fortenbach');
                if isfolder(resourceDir)
                    % Look for dated calibration files first.
                    listing = dir(fullfile(resourceDir, 'led_455nm_calibration_*.txt'));
                    if ~isempty(listing)
                        names = sort({listing.name});
                        filePath = fullfile(resourceDir, names{end});
                        return;
                    end
                    % Check for legacy single-name file.
                    legacy = fullfile(resourceDir, 'led_455nm_calibration.txt');
                    if isfile(legacy)
                        filePath = legacy;
                        return;
                    end
                elseif isfile(resourceDir)
                    % getCalibrationResource returned a file path directly.
                    filePath = resourceDir;
                    return;
                end
            catch
                % Package resource unavailable.
            end
        end

        function tf = isSectionHeader(line)
            % True if line contains an objective identifier (4x, 10x, or
            % 60x) and is NOT a tab-separated data line.
            tf = false;
            if isempty(line)
                return;
            end
            % Must contain an objective identifier.
            if isempty(regexp(line, '(?:^|\s)(4|10|60)x(?:\s|$)', 'once'))
                return;
            end
            % Must NOT look like a data line (starts with number<TAB>).
            if ~isempty(regexp(line, '^\d+\.?\d*\t', 'once'))
                return;
            end
            tf = true;
        end

        function objective = extractObjective(line)
            % Extract objective string ('4x', '10x', '60x') from a header line.
            tokens = regexp(line, '(4|10|60)x', 'tokens', 'once');
            if ~isempty(tokens)
                objective = [tokens{1} 'x'];
            else
                objective = '';
            end
        end

        function [voltage, power_W] = parseDataLine(line)
            % Parse a data line: voltage<TAB>value [unit]
            % Returns voltage in volts and power in watts.
            voltage = NaN;
            power_W = NaN;

            tabIdx = strfind(line, char(9));
            if isempty(tabIdx)
                return;
            end

            voltage = str2double(strtrim(line(1:tabIdx(1)-1)));
            if isnan(voltage)
                return;
            end

            power_W = fortenbachlab.util.LEDCalibration.parseValueToWatts( ...
                strtrim(line(tabIdx(1)+1:end)));
        end

        function watts = parseValueToWatts(valueStr)
            % Parse a value string like "0.18 nW", "77.7 uW", "0.406 mW",
            % or "0.797" (default unit: mW). Returns value in watts.
            tokens = regexp(valueStr, ...
                '^([\d.eE+-]+)\s*(nW|uW|mW)?$', 'tokens', 'once');
            if isempty(tokens)
                watts = NaN;
                return;
            end

            val = str2double(tokens{1});
            if isnan(val)
                watts = NaN;
                return;
            end

            if numel(tokens) < 2 || isempty(tokens{2})
                unit = 'mW';
            else
                unit = tokens{2};
            end

            switch unit
                case 'nW'
                    watts = val * 1e-9;
                case 'uW'
                    watts = val * 1e-6;
                case 'mW'
                    watts = val * 1e-3;
                otherwise
                    watts = val * 1e-3;
            end
        end

        function spotDiameters = parseSpotDiameters(lines)
            % Extract spot diameters from comment lines in the file header.
            % Recognizes patterns like "5.5 mm for 4x" and ranges like
            % "0.37-0.44mm" (takes midpoint, assigns to 60x).
            spotDiameters = struct();
            for i = 1:numel(lines)
                ln = lines{i};
                if isempty(ln) || ln(1) ~= '%'
                    continue;
                end
                lnLower = lower(ln);
                if ~contains(lnLower, 'spot') && ~contains(lnLower, 'diameter')
                    continue;
                end
                % Match "X.X mm for Nx" patterns.
                tokens = regexp(ln, ...
                    '([\d.]+)\s*mm\s+for\s+(\d+)x', 'tokens');
                for j = 1:numel(tokens)
                    val = str2double(tokens{j}{1});
                    objNum = tokens{j}{2};
                    spotDiameters.(['x' objNum]) = val;
                end
                % Match range "X.X-X.Xmm" (take midpoint, assign to 60x).
                rangeTokens = regexp(ln, ...
                    '([\d.]+)\s*-\s*([\d.]+)\s*mm', 'tokens');
                if ~isempty(rangeTokens) && ~isfield(spotDiameters, 'x60')
                    lo = str2double(rangeTokens{1}{1});
                    hi = str2double(rangeTokens{1}{2});
                    spotDiameters.x60 = (lo + hi) / 2;
                end
            end
        end

    end

end
