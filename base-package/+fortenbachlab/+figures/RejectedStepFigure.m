classdef RejectedStepFigure < symphonyui.builtin.figures.CustomFigure
    % RejectedStepFigure  Most recent rejected step of an adaptive protocol.
    % Identical to CustomFigure; exists so it can coexist with other
    % CustomFigure-based figures (one handler per class name).

    methods
        function obj = RejectedStepFigure(handleEpochCallback, varargin)
            obj@symphonyui.builtin.figures.CustomFigure(handleEpochCallback, varargin{:});
        end
    end
end
