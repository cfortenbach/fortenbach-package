classdef IvCurveFigure < symphonyui.builtin.figures.CustomFigure
    % IvCurveFigure  IV curve summary. Identical to CustomFigure; exists only so a protocol
    % can show several callback-driven figures at once (FigureHandlerManager
    % keeps one handler per class name).

    methods
        function obj = IvCurveFigure(handleEpochCallback, varargin)
            obj@symphonyui.builtin.figures.CustomFigure(handleEpochCallback, varargin{:});
        end
    end
end
