import React from 'react';
import classNames from 'classnames';

const Pills = React.createClass({
  render() {
    return (
      <div className={classNames('pills', this.props.className)}>
        {this.props.children}
      </div>
    );
  }
});

export default Pills;
