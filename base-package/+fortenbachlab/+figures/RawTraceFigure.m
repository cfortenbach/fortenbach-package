classdef RawTraceFigure < symphonyui.builtin.figures.CustomFigure
    % RawTraceFigure  Raw current traces. Identical to CustomFigure; exists only so a protocol
    % can show several callback-driven figures at once (FigureHandlerManager
    % keeps one handler per class name).

    methods
        function obj = RawTraceFigure(handleEpochCallback, varargin)
            obj@symphonyui.builtin.figures.CustomFigure(handleEpochCallback, varargin{:});
        end
    end
end
